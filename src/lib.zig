//! zigmarkdoc - Deterministic Markdown documentation generator for Zig
//!
//! Extracts declarations, signatures, and doc comments from Zig source files,
//! producing sorted, reproducible Markdown output.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

/// Categories for sorting declarations
pub const Category = enum {
    import,
    type_alias,
    error_set,
    @"enum",
    @"struct",
    @"union",
    constant,
    variable,
    function,

    /// Order for sorting - lower is earlier in output
    pub fn order(self: Category) u8 {
        return @intFromEnum(self);
    }
};

/// A parsed declaration from the source file
pub const Declaration = struct {
    name: []const u8,
    category: Category,
    is_pub: bool,
    doc_comment: ?[]const u8,
    signature: []const u8,
    start_line: usize,
    end_line: usize,
    /// Nested declarations (for structs, unions, enums)
    members: []Declaration,

    /// For sorting: category, then pub/non-pub, then alphabetical
    pub fn lessThan(_: void, a: Declaration, b: Declaration) bool {
        // First by category
        if (a.category.order() != b.category.order()) {
            return a.category.order() < b.category.order();
        }
        // Then pub before non-pub
        if (a.is_pub != b.is_pub) {
            return a.is_pub;
        }
        // Then alphabetical
        return std.mem.lessThan(u8, a.name, b.name);
    }
};

/// Parsed module representing a single Zig source file
pub const Module = struct {
    allocator: Allocator,
    path: []const u8,
    name: []const u8,
    doc_comment: ?[]const u8,
    declarations: []Declaration,

    pub fn deinit(self: *Module) void {
        self.freeDeclarations(self.declarations);
        if (self.doc_comment) |dc| self.allocator.free(dc);
        self.allocator.free(self.name);
        self.allocator.free(self.path);
        self.allocator.free(self.declarations);
    }

    fn freeDeclarations(self: *Module, decls: []Declaration) void {
        for (decls) |*decl| {
            self.allocator.free(decl.name);
            if (decl.doc_comment) |dc| self.allocator.free(dc);
            self.allocator.free(decl.signature);
            self.freeDeclarations(decl.members);
            self.allocator.free(decl.members);
        }
    }
};

/// Parser for extracting declarations from Zig source
pub const Parser = struct {
    allocator: Allocator,
    source: [:0]const u8,
    ast: Ast,
    include_private: bool,

    pub const Error = error{
        OutOfMemory,
        ParseError,
    };

    pub fn init(allocator: Allocator, source: [:0]const u8, include_private: bool) Error!Parser {
        var ast = try Ast.parse(allocator, source, .zig);
        if (ast.errors.len > 0) {
            ast.deinit(allocator);
            return error.ParseError;
        }
        return .{
            .allocator = allocator,
            .source = source,
            .ast = ast,
            .include_private = include_private,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.ast.deinit(self.allocator);
    }

    /// Parse the source and return a Module
    pub fn parse(self: *Parser, path: []const u8) !Module {
        var declarations: std.ArrayList(Declaration) = .empty;
        errdefer {
            for (declarations.items) |*decl| {
                self.allocator.free(decl.name);
                if (decl.doc_comment) |dc| self.allocator.free(dc);
                self.allocator.free(decl.signature);
            }
            declarations.deinit(self.allocator);
        }

        // Extract container doc comment (//!)
        const doc_comment = try self.extractContainerDocComment();

        // Process root declarations
        for (self.ast.rootDecls()) |node_idx| {
            if (try self.extractDeclaration(node_idx)) |decl| {
                try declarations.append(self.allocator, decl);
            }
        }

        // Sort declarations
        std.mem.sort(Declaration, declarations.items, {}, Declaration.lessThan);

        // Sort nested members too
        for (declarations.items) |*decl| {
            std.mem.sort(Declaration, decl.members, {}, Declaration.lessThan);
        }

        // Derive module name from path
        const name = try self.deriveModuleName(path);

        return .{
            .allocator = self.allocator,
            .path = try self.allocator.dupe(u8, path),
            .name = name,
            .doc_comment = doc_comment,
            .declarations = try declarations.toOwnedSlice(self.allocator),
        };
    }

    fn deriveModuleName(self: *Parser, path: []const u8) ![]const u8 {
        const basename = std.fs.path.basename(path);
        const stem = std.fs.path.stem(basename);
        return try self.allocator.dupe(u8, stem);
    }

    fn extractContainerDocComment(self: *Parser) Error!?[]const u8 {
        const tags = self.ast.tokens.items(.tag);
        const starts = self.ast.tokens.items(.start);

        var doc_lines: std.ArrayList(u8) = .empty;
        errdefer doc_lines.deinit(self.allocator);

        var i: usize = 0;
        while (i < tags.len and tags[i] == .container_doc_comment) : (i += 1) {
            const start = starts[i];
            // NOTE: We intentionally scan to newline rather than next token start.
            // Using next token would capture trailing // comments (since they're not
            // tokenized), but that's inconsistent with how /// doc comments work.
            // Revisit if we want to preserve regular comments more broadly.
            var end = start;
            while (end < self.source.len and self.source[end] != '\n') : (end += 1) {}
            const line = self.source[start..end];

            // Strip the //! prefix and leading space
            const content = std.mem.trimLeft(u8, line, "/!");
            const trimmed = std.mem.trimLeft(u8, content, " ");
            const final = std.mem.trimRight(u8, trimmed, " \n\r");

            if (doc_lines.items.len > 0) {
                try doc_lines.append(self.allocator, '\n');
            }
            try doc_lines.appendSlice(self.allocator, final);
        }

        if (doc_lines.items.len == 0) {
            return null;
        }
        return try doc_lines.toOwnedSlice(self.allocator);
    }

    fn extractDeclaration(self: *Parser, node_idx: Ast.Node.Index) Error!?Declaration {
        const idx = @intFromEnum(node_idx);
        const node_tag = self.ast.nodes.items(.tag)[idx];
        const first_tok = self.ast.firstToken(node_idx);
        const tags = self.ast.tokens.items(.tag);

        const is_pub = tags[first_tok] == .keyword_pub;

        // Skip non-pub if not including private
        if (!is_pub and !self.include_private) {
            return null;
        }

        return switch (node_tag) {
            .simple_var_decl => try self.extractVarDecl(node_idx, is_pub),
            .fn_decl => try self.extractFnDecl(node_idx, is_pub),
            .test_decl => null, // Skip tests for now
            else => null,
        };
    }

    fn extractVarDecl(self: *Parser, node_idx: Ast.Node.Index, is_pub: bool) Error!?Declaration {
        const var_decl = self.ast.fullVarDecl(node_idx) orelse return null;

        const name_tok = var_decl.ast.mut_token + 1; // Token after 'const'/'var'
        const name = self.ast.tokenSlice(name_tok);

        // Determine category based on init value
        const category = self.categorizeVarDecl(var_decl);

        const first_tok = self.ast.firstToken(node_idx);
        const last_tok = self.ast.lastToken(node_idx);

        const doc_comment = try self.extractDocComment(first_tok);

        // For containers and error sets, extract signature up to (not including) the opening brace
        const signature = switch (category) {
            .@"struct", .@"union", .@"enum" => try self.extractContainerSignature(first_tok, var_decl.ast.init_node),
            .error_set => try self.extractErrorSetSignature(first_tok, var_decl.ast.init_node),
            else => try self.extractVarSignature(first_tok, var_decl),
        };

        // Extract members for containers and error sets
        var members: []Declaration = &.{};
        if (var_decl.ast.init_node != .none) {
            members = switch (category) {
                .error_set => try self.extractErrorSetMembers(var_decl.ast.init_node),
                else => try self.extractContainerMembers(var_decl.ast.init_node),
            };
        }

        return .{
            .name = try self.allocator.dupe(u8, name),
            .category = category,
            .is_pub = is_pub,
            .doc_comment = doc_comment,
            .signature = signature,
            .start_line = self.offsetToLine(self.ast.tokens.items(.start)[first_tok]),
            .end_line = self.offsetToLine(self.ast.tokens.items(.start)[last_tok]),
            .members = members,
        };
    }

    fn categorizeVarDecl(self: *Parser, var_decl: Ast.full.VarDecl) Category {
        if (var_decl.ast.init_node == .none) {
            // No init - check if const or var
            const tags = self.ast.tokens.items(.tag);
            if (tags[var_decl.ast.mut_token] == .keyword_var) {
                return .variable;
            }
            return .constant;
        }

        const init_idx = @intFromEnum(var_decl.ast.init_node);
        const init_tag = self.ast.nodes.items(.tag)[init_idx];

        // Check for @import or @import(...).field patterns
        // Use source text inspection as it's simpler and handles all cases
        const init_node_idx: Ast.Node.Index = @enumFromInt(@intFromEnum(var_decl.ast.init_node));
        const init_first_tok = self.ast.firstToken(init_node_idx);
        const init_start = self.ast.tokens.items(.start)[init_first_tok];
        // Check if this looks like an @import expression
        const remaining = self.source[init_start..];
        if (std.mem.startsWith(u8, remaining, "@import")) {
            return .import;
        }

        // Check for container types
        var buf: [2]Ast.Node.Index = undefined;
        if (self.ast.fullContainerDecl(&buf, init_node_idx)) |cont| {
            const container_tok = cont.ast.main_token;
            const container_tag = self.ast.tokens.items(.tag)[container_tok];

            return switch (container_tag) {
                .keyword_struct => .@"struct",
                .keyword_union => .@"union",
                .keyword_enum => .@"enum",
                else => .type_alias,
            };
        }

        // Check for error set
        if (init_tag == .error_set_decl) {
            return .error_set;
        }

        // Check if it's a type alias (fn type, etc.)
        if (init_tag == .fn_proto or init_tag == .fn_proto_simple or
            init_tag == .fn_proto_multi or init_tag == .fn_proto_one)
        {
            return .type_alias;
        }

        // Default based on mut_token
        const tags = self.ast.tokens.items(.tag);
        if (tags[var_decl.ast.mut_token] == .keyword_var) {
            return .variable;
        }
        return .constant;
    }

    fn extractFnDecl(self: *Parser, node_idx: Ast.Node.Index, is_pub: bool) Error!?Declaration {
        // Use fullFnProto to get function prototype info
        var buf: [1]Ast.Node.Index = undefined;
        const fn_proto = self.ast.fullFnProto(&buf, node_idx) orelse return null;

        // Get function name from the name token
        const name = if (fn_proto.name_token) |tok| self.ast.tokenSlice(tok) else "anonymous";

        const first_tok = self.ast.firstToken(node_idx);
        const doc_comment = try self.extractDocComment(first_tok);

        // For signature, extract the function prototype only (not the body)
        // proto_data.node_and_node[0] is the prototype node
        const proto_data = self.ast.nodeData(node_idx);
        const proto_node_idx = proto_data.node_and_node[0];
        const proto_last_tok = self.ast.lastToken(proto_node_idx);

        // Use extractSourceRange to get exact token range (not to end of line)
        const signature = try self.extractSourceRange(first_tok, proto_last_tok);

        return .{
            .name = try self.allocator.dupe(u8, name),
            .category = .function,
            .is_pub = is_pub,
            .doc_comment = doc_comment,
            .signature = signature,
            .start_line = self.offsetToLine(self.ast.tokens.items(.start)[first_tok]),
            .end_line = self.offsetToLine(self.ast.tokens.items(.start)[proto_last_tok]),
            .members = &.{},
        };
    }

    fn extractContainerMembers(self: *Parser, init_node: Ast.Node.OptionalIndex) Error![]Declaration {
        if (init_node == .none) return &.{};

        var buf: [2]Ast.Node.Index = undefined;
        const init_idx: Ast.Node.Index = @enumFromInt(@intFromEnum(init_node));
        const container = self.ast.fullContainerDecl(&buf, init_idx) orelse return &.{};

        var members: std.ArrayList(Declaration) = .empty;
        errdefer {
            for (members.items) |*m| {
                self.allocator.free(m.name);
                if (m.doc_comment) |dc| self.allocator.free(dc);
                self.allocator.free(m.signature);
            }
            members.deinit(self.allocator);
        }

        for (container.ast.members) |member_idx| {
            const midx = @intFromEnum(member_idx);
            const member_tag = self.ast.nodes.items(.tag)[midx];
            const first_tok = self.ast.firstToken(member_idx);
            const tags = self.ast.tokens.items(.tag);
            const is_pub = tags[first_tok] == .keyword_pub;

            // Fields don't have pub/private visibility - always include them
            const is_field = member_tag == .container_field or
                member_tag == .container_field_init or
                member_tag == .container_field_align;

            if (!is_field and !is_pub and !self.include_private) {
                continue;
            }

            const decl: ?Declaration = switch (member_tag) {
                .container_field, .container_field_init, .container_field_align => try self.extractField(member_idx),
                .fn_decl => try self.extractFnDecl(member_idx, is_pub),
                .simple_var_decl => try self.extractVarDecl(member_idx, is_pub),
                else => null,
            };

            if (decl) |d| {
                try members.append(self.allocator, d);
            }
        }

        return try members.toOwnedSlice(self.allocator);
    }

    fn extractField(self: *Parser, node_idx: Ast.Node.Index) Error!?Declaration {
        const field = self.ast.fullContainerField(node_idx) orelse return null;

        const name = self.ast.tokenSlice(field.ast.main_token);
        const first_tok = self.ast.firstToken(node_idx);
        const last_tok = self.ast.lastToken(node_idx);

        const doc_comment = try self.extractDocComment(first_tok);
        const signature = try self.extractSourceLines(first_tok, last_tok);

        return .{
            .name = try self.allocator.dupe(u8, name),
            .category = .constant, // Fields use constant category for sorting
            .is_pub = true, // Struct fields are always accessible
            .doc_comment = doc_comment,
            .signature = signature,
            .start_line = self.offsetToLine(self.ast.tokens.items(.start)[first_tok]),
            .end_line = self.offsetToLine(self.ast.tokens.items(.start)[last_tok]),
            .members = &.{},
        };
    }

    fn extractDocComment(self: *Parser, first_tok: u32) Error!?[]const u8 {
        const tags = self.ast.tokens.items(.tag);
        const starts = self.ast.tokens.items(.start);

        if (first_tok == 0) return null;

        var doc_lines: std.ArrayList(u8) = .empty;
        errdefer doc_lines.deinit(self.allocator);

        // Look backwards from first_tok for doc comments
        var found_any = false;

        // First, find all consecutive doc comments going backwards
        var doc_tokens: std.ArrayList(u32) = .empty;
        defer doc_tokens.deinit(self.allocator);

        var t: u32 = first_tok - 1;
        while (true) {
            if (tags[t] == .doc_comment) {
                try doc_tokens.append(self.allocator, t);
                found_any = true;
            } else {
                break;
            }
            if (t == 0) break;
            t -= 1;
        }

        if (!found_any) return null;

        // Reverse to get correct order
        std.mem.reverse(u32, doc_tokens.items);

        for (doc_tokens.items) |tok| {
            const start = starts[tok];
            const end = if (tok + 1 < starts.len) starts[tok + 1] else self.source.len;
            const line = self.source[start..end];

            // Strip the /// prefix
            const content = std.mem.trimLeft(u8, line, "/");
            const trimmed = std.mem.trimLeft(u8, content, " ");
            const final = std.mem.trimRight(u8, trimmed, " \n\r");

            if (doc_lines.items.len > 0) {
                try doc_lines.append(self.allocator, '\n');
            }
            try doc_lines.appendSlice(self.allocator, final);
        }

        if (doc_lines.items.len == 0) return null;
        return try doc_lines.toOwnedSlice(self.allocator);
    }

    fn extractSignature(self: *Parser, first_tok: u32, last_tok: u32, category: Category) Error![]const u8 {
        _ = category;
        return try self.extractSourceLines(first_tok, last_tok);
    }

    /// Extract signature for container types (struct, union, enum)
    /// Stops just before the opening brace
    fn extractContainerSignature(self: *Parser, first_tok: u32, init_node: Ast.Node.OptionalIndex) Error![]const u8 {
        if (init_node == .none) {
            return try self.allocator.dupe(u8, "");
        }

        // Find the container's opening brace
        var buf: [2]Ast.Node.Index = undefined;
        const init_idx: Ast.Node.Index = @enumFromInt(@intFromEnum(init_node));
        if (self.ast.fullContainerDecl(&buf, init_idx)) |container| {
            // The opening brace is right after the main_token (struct/union/enum keyword)
            const tags = self.ast.tokens.items(.tag);
            var tok = container.ast.main_token;
            while (tok < tags.len and tags[tok] != .l_brace) : (tok += 1) {}

            // Extract from first_tok to just before l_brace
            if (tok > first_tok) {
                return try self.extractSourceRange(first_tok, tok - 1);
            }
        }

        // Fallback: extract to init node's first token
        const init_first_tok = self.ast.firstToken(init_idx);
        return try self.extractSourceLines(first_tok, init_first_tok);
    }

    /// Extract signature for non-container variable declarations
    fn extractVarSignature(self: *Parser, first_tok: u32, var_decl: Ast.full.VarDecl) Error![]const u8 {
        // For simple var decls (constants, imports), include up to end of init expr
        if (var_decl.ast.init_node != .none) {
            const init_idx: Ast.Node.Index = @enumFromInt(@intFromEnum(var_decl.ast.init_node));
            const last_tok = self.ast.lastToken(init_idx);
            return try self.extractSourceLines(first_tok, last_tok);
        }
        // No init - just extract the declaration part
        return try self.extractSourceLines(first_tok, var_decl.ast.mut_token + 1);
    }

    /// Extract signature for error sets - stop at opening brace
    fn extractErrorSetSignature(self: *Parser, first_tok: u32, init_node: Ast.Node.OptionalIndex) Error![]const u8 {
        if (init_node == .none) {
            return try self.allocator.dupe(u8, "");
        }

        const init_idx: Ast.Node.Index = @enumFromInt(@intFromEnum(init_node));
        const init_first_tok = self.ast.firstToken(init_idx);

        // Find the opening brace
        const tags = self.ast.tokens.items(.tag);
        var tok = init_first_tok;
        while (tok < tags.len and tags[tok] != .l_brace) : (tok += 1) {}

        // Extract from first_tok to just before l_brace
        if (tok > first_tok) {
            return try self.extractSourceRange(first_tok, tok - 1);
        }
        return try self.extractSourceRange(first_tok, init_first_tok);
    }

    /// Extract error names from an error set by scanning tokens
    fn extractErrorSetMembers(self: *Parser, init_node: Ast.Node.OptionalIndex) Error![]Declaration {
        if (init_node == .none) return &.{};

        const init_idx: Ast.Node.Index = @enumFromInt(@intFromEnum(init_node));
        const init_tag = self.ast.nodes.items(.tag)[@intFromEnum(init_idx)];

        if (init_tag != .error_set_decl) return &.{};

        var members: std.ArrayList(Declaration) = .empty;
        errdefer {
            for (members.items) |*m| {
                self.allocator.free(m.name);
                if (m.doc_comment) |dc| self.allocator.free(dc);
                self.allocator.free(m.signature);
            }
            members.deinit(self.allocator);
        }

        // Scan tokens from first to last of error_set_decl for identifiers
        const first_tok = self.ast.firstToken(init_idx);
        const last_tok = self.ast.lastToken(init_idx);
        const tags = self.ast.tokens.items(.tag);

        var tok = first_tok;
        while (tok <= last_tok) : (tok += 1) {
            if (tags[tok] == .identifier) {
                const name = self.ast.tokenSlice(tok);
                const doc_comment = try self.extractDocComment(tok);

                try members.append(self.allocator, .{
                    .name = try self.allocator.dupe(u8, name),
                    .category = .constant, // Use constant for sorting purposes
                    .is_pub = true,
                    .doc_comment = doc_comment,
                    .signature = try self.allocator.dupe(u8, name),
                    .start_line = self.offsetToLine(self.ast.tokens.items(.start)[tok]),
                    .end_line = self.offsetToLine(self.ast.tokens.items(.start)[tok]),
                    .members = &.{},
                });
            }
        }

        return try members.toOwnedSlice(self.allocator);
    }

    /// Extract source from first_tok to last_tok (inclusive), trimmed
    fn extractSourceRange(self: *Parser, first_tok: u32, last_tok: u32) Error![]const u8 {
        const starts = self.ast.tokens.items(.start);

        const start_offset = starts[first_tok];
        // Get end of last token
        var end_offset = starts[last_tok];
        const last_slice = self.ast.tokenSlice(last_tok);
        end_offset += @intCast(last_slice.len);

        const slice = self.source[start_offset..end_offset];
        return try self.allocator.dupe(u8, std.mem.trim(u8, slice, " \n\r\t"));
    }

    fn extractSourceLines(self: *Parser, first_tok: u32, last_tok: u32) Error![]const u8 {
        const starts = self.ast.tokens.items(.start);

        const start_offset = starts[first_tok];
        // Find end of last token's line
        var end_offset = starts[last_tok];
        while (end_offset < self.source.len and self.source[end_offset] != '\n') {
            end_offset += 1;
        }

        const slice = self.source[start_offset..end_offset];
        return try self.allocator.dupe(u8, std.mem.trim(u8, slice, " \n\r\t"));
    }

    fn offsetToLine(self: *Parser, offset: usize) usize {
        var line: usize = 1;
        for (self.source[0..@min(offset, self.source.len)]) |c| {
            if (c == '\n') line += 1;
        }
        return line;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "parse simple function" {
    const source =
        \\/// A test function
        \\pub fn hello() void {}
    ;

    var parser = try Parser.init(std.testing.allocator, source, false);
    defer parser.deinit();

    var module = try parser.parse("test.zig");
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.declarations.len);
    try std.testing.expectEqualStrings("hello", module.declarations[0].name);
    try std.testing.expectEqual(Category.function, module.declarations[0].category);
    try std.testing.expect(module.declarations[0].is_pub);
    try std.testing.expectEqualStrings("A test function", module.declarations[0].doc_comment.?);
}

test "parse struct with members" {
    const source =
        \\/// A test struct
        \\pub const MyStruct = struct {
        \\  /// Name field
        \\  name: []const u8,
        \\
        \\  /// Initialize
        \\  pub fn init() MyStruct {
        \\    return .{ .name = "test" };
        \\  }
        \\};
    ;

    var parser = try Parser.init(std.testing.allocator, source, false);
    defer parser.deinit();

    var module = try parser.parse("test.zig");
    defer module.deinit();

    try std.testing.expectEqual(@as(usize, 1), module.declarations.len);
    const s = module.declarations[0];
    try std.testing.expectEqualStrings("MyStruct", s.name);
    try std.testing.expectEqual(Category.@"struct", s.category);
    try std.testing.expectEqual(@as(usize, 2), s.members.len);
}

test "sorting order" {
    const source =
        \\const z_import = @import("z.zig");
        \\pub const a_import = @import("a.zig");
        \\pub fn beta() void {}
        \\pub fn alpha() void {}
        \\pub const MyStruct = struct {};
    ;

    var parser = try Parser.init(std.testing.allocator, source, true);
    defer parser.deinit();

    var module = try parser.parse("test.zig");
    defer module.deinit();

    // Should be: pub import, non-pub import, struct, functions (alpha order)
    try std.testing.expectEqualStrings("a_import", module.declarations[0].name);
    try std.testing.expectEqualStrings("z_import", module.declarations[1].name);
    try std.testing.expectEqualStrings("MyStruct", module.declarations[2].name);
    try std.testing.expectEqualStrings("alpha", module.declarations[3].name);
    try std.testing.expectEqualStrings("beta", module.declarations[4].name);
}

test "container doc comment" {
    const source =
        \\//! Module documentation
        \\//! Second line
        \\
        \\pub fn foo() void {}
    ;

    var parser = try Parser.init(std.testing.allocator, source, false);
    defer parser.deinit();

    var module = try parser.parse("test.zig");
    defer module.deinit();

    try std.testing.expectEqualStrings("Module documentation\nSecond line", module.doc_comment.?);
}
