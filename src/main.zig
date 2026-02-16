//! zigmarkdoc CLI - Deterministic Markdown documentation generator for Zig

const std = @import("std");
const lib = @import("lib");

const Parser = lib.Parser;
const Module = lib.Module;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = parseArgs(args) catch |err| {
        if (err == error.HelpRequested) {
            return;
        }
        return err;
    };

    // Read source file
    const source = std.fs.cwd().readFileAllocOptions(
        allocator,
        config.input_path,
        1024 * 1024 * 10, // 10MB max
        null,
        .@"1",
        0,
    ) catch |err| {
        std.debug.print("Error reading file '{s}': {}\n", .{ config.input_path, err });
        std.process.exit(3);
    };
    defer allocator.free(source);

    // Parse
    var parser = Parser.init(allocator, source, config.include_private) catch |err| {
        std.debug.print("Parse error: {}\n", .{err});
        std.process.exit(2);
    };
    defer parser.deinit();

    var module = try parser.parse(config.input_path);
    defer module.deinit();

    // Render output
    const output = try renderMarkdown(allocator, &module, config);
    defer allocator.free(output);

    // Output or check
    if (config.check_mode) {
        const existing = std.fs.cwd().readFileAlloc(allocator, config.output_path.?, 1024 * 1024 * 10) catch |err| {
            std.debug.print("Error reading existing file for check: {}\n", .{err});
            std.process.exit(3);
        };
        defer allocator.free(existing);

        if (!std.mem.eql(u8, existing, output)) {
            std.debug.print("Documentation mismatch: output would differ from existing file\n", .{});
            std.process.exit(1);
        }
    } else if (config.output_path) |path| {
        const file = std.fs.cwd().createFile(path, .{}) catch |err| {
            std.debug.print("Error creating output file: {}\n", .{err});
            std.process.exit(3);
        };
        defer file.close();
        file.writeAll(output) catch |err| {
            std.debug.print("Error writing output: {}\n", .{err});
            std.process.exit(3);
        };
    } else {
        const stdout_file = std.fs.File.stdout();
        stdout_file.writeAll(output) catch |err| {
            std.debug.print("Error writing to stdout: {}\n", .{err});
            std.process.exit(3);
        };
    }
}

const Config = struct {
    input_path: []const u8,
    output_path: ?[]const u8 = null,
    check_mode: bool = false,
    include_private: bool = false,
    no_source: bool = false,
    header_level: u8 = 1,
    individual_headings: bool = false,
};

fn parseArgs(args: []const []const u8) !Config {
    var config = Config{ .input_path = undefined };
    var input_set = false;

    var i: usize = 1; // Skip program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printHelp();
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            std.debug.print("zigmarkdoc 0.1.0\n", .{});
            return error.HelpRequested;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --output requires a path\n", .{});
                std.process.exit(4);
            }
            config.output_path = args[i];
        } else if (std.mem.eql(u8, arg, "--check")) {
            config.check_mode = true;
        } else if (std.mem.eql(u8, arg, "--include-private") or std.mem.eql(u8, arg, "-p")) {
            config.include_private = true;
        } else if (std.mem.eql(u8, arg, "--no-source")) {
            config.no_source = true;
        } else if (std.mem.eql(u8, arg, "--individual-headings")) {
            config.individual_headings = true;
        } else if (std.mem.eql(u8, arg, "--header-level")) {
            i += 1;
            if (i >= args.len) {
                std.debug.print("Error: --header-level requires a number\n", .{});
                std.process.exit(4);
            }
            config.header_level = std.fmt.parseInt(u8, args[i], 10) catch {
                std.debug.print("Error: invalid header level\n", .{});
                std.process.exit(4);
            };
        } else if (arg[0] == '-') {
            std.debug.print("Unknown option: {s}\n", .{arg});
            std.process.exit(4);
        } else {
            if (input_set) {
                std.debug.print("Error: multiple input files not supported\n", .{});
                std.process.exit(4);
            }
            config.input_path = arg;
            input_set = true;
        }
    }

    if (!input_set) {
        std.debug.print("Error: no input file specified\n", .{});
        printHelp();
        std.process.exit(4);
    }

    if (config.check_mode and config.output_path == null) {
        std.debug.print("Error: --check requires --output\n", .{});
        std.process.exit(4);
    }

    return config;
}

fn printHelp() void {
    const help =
        \\zigmarkdoc - Deterministic Markdown documentation generator for Zig
        \\
        \\Usage: zigmarkdoc [OPTIONS] <INPUT>
        \\
        \\Arguments:
        \\  <INPUT>                   Zig source file to document
        \\
        \\Options:
        \\  -o, --output <PATH>       Output file path (default: stdout)
        \\  --check                   Exit 1 if output differs from existing file
        \\  -p, --include-private     Include non-pub declarations
        \\  --no-source               Omit source code blocks
        \\  --individual-headings     Use verbose format with heading per declaration
        \\  --header-level <N>        Starting header level (default: 1)
        \\  -V, --version             Print version
        \\  -h, --help                Print help
        \\
    ;
    std.debug.print("{s}", .{help});
}

fn renderMarkdown(allocator: std.mem.Allocator, module: *const Module, config: Config) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);

    const writer = output.writer(allocator);
    const h1 = headerPrefix(config.header_level);

    // Module header
    try writer.print("{s} {s}\n\n", .{ h1, module.name });

    // Module doc comment
    if (module.doc_comment) |doc| {
        try writer.print("{s}\n\n", .{doc});
    }

    // Render imports as a single grouped block (concise)
    var has_imports = false;
    for (module.declarations) |decl| {
        if (decl.category == .import) {
            if (!has_imports) {
                try writer.print("{s} Imports\n\n```zig\n", .{headerPrefix(config.header_level + 1)});
                has_imports = true;
            }
            try writer.print("{s}\n", .{decl.signature});
        }
    }
    if (has_imports) {
        try writer.writeAll("```\n\n");
    }

    // Render non-import declarations
    if (config.individual_headings) {
        // Verbose format: individual headings for each declaration
        var current_category: ?lib.Category = null;

        for (module.declarations) |decl| {
            if (decl.category == .import) continue;

            if (current_category == null or current_category.? != decl.category) {
                current_category = decl.category;
                try writer.print("{s} {s}\n\n", .{ headerPrefix(config.header_level + 1), categoryName(decl.category) });
            }

            try renderDeclaration(writer, allocator, &decl, config, config.header_level + 2);
        }
    } else {
        // Compact format: grouped code blocks per category
        try renderCompact(writer, module, config);
    }

    return try output.toOwnedSlice(allocator);
}

fn renderCompact(writer: anytype, module: *const Module, config: Config) !void {
    var current_category: ?lib.Category = null;
    var category_started = false;

    for (module.declarations, 0..) |decl, i| {
        if (decl.category == .import) continue;

        // Start new category section
        if (current_category == null or current_category.? != decl.category) {
            // Close previous category's code block
            if (category_started) {
                try writer.writeAll("```\n\n");
            }

            current_category = decl.category;
            try writer.print("{s} {s}\n\n", .{ headerPrefix(config.header_level + 1), categoryName(decl.category) });

            if (!config.no_source) {
                try writer.writeAll("```zig\n");
                category_started = true;
            } else {
                category_started = false;
            }
        }

        // Render declaration in compact form
        if (config.no_source) {
            // Just show name and doc
            if (decl.doc_comment) |doc| {
                try writer.print("{s}\n\n", .{doc});
            }
            try writer.print("`{s}`\n\n", .{decl.name});
        } else {
            // Add spacing between declarations
            if (i > 0 and module.declarations[i - 1].category == decl.category) {
                try writer.writeAll("\n");
            }

            // Doc comment as /// prefix
            if (decl.doc_comment) |doc| {
                var lines = std.mem.splitScalar(u8, doc, '\n');
                while (lines.next()) |line| {
                    try writer.print("/// {s}\n", .{line});
                }
            }

            // Check if we have methods to render inside the container
            const has_methods = blk: {
                for (decl.members) |member| {
                    if (member.category == .function) break :blk true;
                }
                break :blk false;
            };

            if (has_methods) {
                // Container with methods: strip closing brace, add methods, then close
                const sig = decl.signature;
                const trimmed = std.mem.trimRight(u8, sig, " \n\r\t");
                // Strip final } if present
                if (std.mem.endsWith(u8, trimmed, "}")) {
                    try writer.print("{s}\n", .{trimmed[0 .. trimmed.len - 1]});
                } else {
                    try writer.print("{s}\n", .{sig});
                }

                // Render methods inside
                for (decl.members) |member| {
                    if (member.category == .function) {
                        try writer.writeAll("\n");
                        if (member.doc_comment) |doc| {
                            var lines = std.mem.splitScalar(u8, doc, '\n');
                            while (lines.next()) |line| {
                                try writer.print("  /// {s}\n", .{line});
                            }
                        }
                        var sig_lines = std.mem.splitScalar(u8, member.signature, '\n');
                        while (sig_lines.next()) |line| {
                            try writer.print("  {s}\n", .{line});
                        }
                    }
                }

                // Close container
                try writer.writeAll("}\n");
            } else {
                // No methods: render signature as-is
                try writer.print("{s}\n", .{decl.signature});
            }
        }
    }

    // Close final category's code block
    if (category_started) {
        try writer.writeAll("```\n\n");
    }
}

fn renderDeclaration(writer: anytype, allocator: std.mem.Allocator, decl: *const lib.Declaration, config: Config, level: u8) !void {
    const h = headerPrefix(level);

    // Declaration header
    try writer.print("{s} `{s}`\n\n", .{ h, decl.name });

    // Doc comment
    if (decl.doc_comment) |doc| {
        try writer.print("{s}\n\n", .{doc});
    }

    // Signature
    if (!config.no_source) {
        try writer.writeAll("```zig\n");
        try writer.print("{s}\n", .{decl.signature});
        try writer.writeAll("```\n\n");
    }

    // Render nested members (fields, methods) for containers
    if (decl.members.len > 0) {
        // Separate fields from methods/other declarations
        var has_fields = false;
        var has_methods = false;

        for (decl.members) |member| {
            if (member.category == .constant and std.mem.indexOfAny(u8, member.signature, "=") == null) {
                // Likely a field (no = in signature)
                has_fields = true;
            } else if (member.category == .function) {
                has_methods = true;
            }
        }

        // For structs/unions, fields are shown in the code block - no table needed
        // For enums/errors without methods, variants are also in the code block
        // Only show variant list/table for enums/errors if they have doc comments
        // that wouldn't be visible in the signature
        if (has_fields) {
            const is_variant_type = decl.category == .@"enum" or decl.category == .error_set;

            if (is_variant_type) {
                // Check if any variants have doc comments
                var any_docs = false;
                for (decl.members) |member| {
                    if (member.category == .constant and std.mem.indexOfAny(u8, member.signature, "=") == null) {
                        if (member.doc_comment != null) {
                            any_docs = true;
                            break;
                        }
                    }
                }

                // Only show table if there are doc comments (they're in the source anyway for ///,
                // but this catches cases where we parsed them)
                if (any_docs) {
                    try writer.writeAll("| Variant | Description |\n");
                    try writer.writeAll("|---------|-------------|\n");
                    for (decl.members) |member| {
                        if (member.category == .constant and std.mem.indexOfAny(u8, member.signature, "=") == null) {
                            const doc = member.doc_comment orelse "";
                            try writer.print("| `{s}` | {s} |\n", .{ member.name, doc });
                        }
                    }
                    try writer.writeAll("\n");
                }
            }
            // For structs/unions: fields are visible in the code block, skip table
        }

        // Render methods as nested declarations
        if (has_methods) {
            for (decl.members) |*member| {
                if (member.category == .function) {
                    try renderDeclaration(writer, allocator, member, config, level + 1);
                }
            }
        }
    }
}

fn headerPrefix(level: u8) []const u8 {
    return switch (level) {
        1 => "#",
        2 => "##",
        3 => "###",
        4 => "####",
        5 => "#####",
        else => "######",
    };
}

fn categoryName(cat: lib.Category) []const u8 {
    return switch (cat) {
        .import => "Imports",
        .type_alias => "Type Aliases",
        .error_set => "Error Sets",
        .@"enum" => "Enums",
        .@"struct" => "Structs",
        .@"union" => "Unions",
        .constant => "Constants",
        .variable => "Variables",
        .function => "Functions",
    };
}

test {
    _ = lib;
}
