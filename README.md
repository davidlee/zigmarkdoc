# zigmarkdoc

Deterministic Markdown documentation generator for Zig codebases.

Inspired by [gomarkdoc](https://github.com/princjef/gomarkdoc), zigmarkdoc extracts structured documentation from Zig source files—declarations, signatures, and comments—producing concise, reproducible Markdown suitable for spec-driven development workflows.

## Motivation

When verifying that implementations match design specifications, you need documentation that is:

- **Deterministic**: identical input always produces identical output
- **Order-independent**: declaration order in source doesn't affect output order
- **Complete**: all comments preserved (doc comments, inline, trailing)
- **Concise**: token-parsimonious for LLM-assisted code review

zigmarkdoc enables workflows where you can diff documentation against a specification, or use `--check` to verify documentation is current without regenerating.

## Scope

### v0.1 (Current Target)

Single-file operation only:
- One `.zig` source file in → one Markdown document out (file or stdout)
- spec-driver handles orchestration across multiple files

### Future

- Directory traversal with `--recursive`
- Glob-based `--exclude` patterns
- Multi-file output
- Regular comment preservation (via secondary source scan or tree-sitter)

## Installation

```bash
# From source (requires Zig 0.15.2+)
zig build -Doptimize=ReleaseSafe

# Install to path
zig build install --prefix ~/.local
```

## Usage

```bash
# Document a single file to stdout
zigmarkdoc src/parser.zig

# Write to file
zigmarkdoc src/parser.zig -o docs/parser.md

# Check mode: exit 1 if docs would change (for CI)
zigmarkdoc src/parser.zig -o docs/parser.md --check

# Include non-public declarations
zigmarkdoc src/parser.zig --include-private
```

<!-- Future: directory traversal
```bash
# Document a directory (each .zig file becomes a section)
zigmarkdoc src/

# Exclude specific files/patterns
zigmarkdoc src/ --exclude 'test_*.zig' --exclude 'build.zig'
```
-->

## Output Format

### File-Level Structure

Unlike Go (where all files in a directory merge into one package), Zig's module system treats each file as a distinct namespace. zigmarkdoc preserves this:

```markdown
# module_name

Top-level doc comment for the file (if present).

## Structs

### `MyStruct`

Doc comment for struct.

| Field | Type | Description |
|-------|------|-------------|
| `name` | `[]const u8` | Field doc comment |
| `count` | `usize` | Inline comment |

### `MyStruct.init`

```zig
pub fn init(allocator: std.mem.Allocator) !MyStruct
```

Doc comment for method.

## Functions

### `processItem`

```zig
pub fn processItem(item: Item, options: Options) !Result
```

Doc comment for function.

## Constants

### `VERSION`

```zig
pub const VERSION: []const u8 = "1.0.0"
```

## Types

### `Callback`

```zig
pub const Callback = fn (ctx: *anyopaque) void
```

## Errors

### `Error`

```zig
pub const Error = error{
    InvalidInput,
    OutOfMemory,
    Timeout,
};
```
```
```

### Ordering

All declarations are sorted for determinism. Categories appear in this order:

1. Imports
2. Type aliases
3. Error sets
4. Enums
5. Structs (with nested fields/methods)
6. Unions (with nested fields/methods)
7. Constants
8. Variables
9. Functions

Within each category:
- `pub` declarations first, then non-`pub`
- Alphabetical by name within each visibility group

For structs/unions/enums, nested members follow the same pattern (pub methods first, then non-pub, alphabetical within).

### Comment Preservation

zigmarkdoc captures **doc comments only**:

| Comment Type | Source | Preserved |
|--------------|--------|-----------|
| Container doc | `//! text` | Yes - becomes module description |
| Doc comment | `/// text` | Yes - attached to following declaration |
| Regular comment | `// text` | No |
| Trailing comment | `field, // text` | No |

**Why not regular comments?**

Zig's `std.zig.Ast` tokenizer discards regular `//` comments during parsing—only `///` and `//!` doc comments become tokens. Rather than implement a secondary comment-extraction pass, we accept this limitation.

This is arguably a feature: regular comments describe *implementation*, while doc comments describe *interface*. For spec-driven development, interface stability matters; implementation comments can change freely without invalidating the spec.

## Flags

| Flag | Short | Description | Status |
|------|-------|-------------|--------|
| `--output` | `-o` | Output file path (default: stdout) | v0.1 |
| `--check` | | Exit 1 if output differs from existing file | v0.1 |
| `--include-private` | `-p` | Include non-`pub` declarations | v0.1 |
| `--no-source` | | Omit source code blocks, show signatures only | v0.1 |
| `--format` | `-f` | Output format: `markdown` (default), `json` | v0.1 |
| `--header-level` | | Starting header level (default: 1) | v0.1 |
| `--version` | `-V` | Print version | v0.1 |
| `--help` | `-h` | Print help | v0.1 |
| `--exclude` | `-e` | Glob pattern for files to skip (repeatable) | Future |
| `--recursive` | `-r` | Process subdirectories | Future |

## JSON Output

For programmatic consumption, `--format json` produces:

```json
{
  "path": "src/parser.zig",
  "module": "parser",
  "doc": "File-level documentation.",
  "structs": [
    {
      "name": "Token",
      "public": true,
      "doc": "Represents a lexical token.",
      "fields": [
        {
          "name": "tag",
          "type": "Tag",
          "doc": "Token type identifier."
        }
      ],
      "methods": [...]
    }
  ],
  "functions": [...],
  "constants": [...],
  "types": [...],
  "errors": [...]
}
```

## Determinism Guarantees

1. **Lexicographic ordering**: all declarations sorted by name
2. **Stable formatting**: no trailing whitespace, consistent newlines
3. **No timestamps**: output contains no dates or generation metadata
4. **Reproducible hashing**: same input file = same SHA256 of output

These properties enable:
- `--check` for CI verification
- `diff`-based change detection
- Version control of generated docs

## Zig Version Support

| Zig Version | Status |
|-------------|--------|
| 0.15.x | Primary target |
| 0.14.x | Planned |
| 0.13.x | Planned |

The parser uses Zig's `std.zig.Ast` which varies between versions. Multi-version support will be achieved via build-time detection or runtime selection.

## Differences from gomarkdoc

| Aspect | gomarkdoc | zigmarkdoc |
|--------|-----------|------------|
| Module granularity | Directory (package) | File (module) |
| Method grouping | By receiver type | By parent struct/union |
| Visibility | Exported = capitalized | Explicit `pub` keyword |
| Generics | Type parameters | `comptime` parameters |
| Test functions | Ignored | Optionally included |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Documentation mismatch (with `--check`) |
| 2 | Parse error in source |
| 3 | I/O error |
| 4 | Invalid arguments |

## Examples

### Spec-Driven Workflow

```bash
# Generate initial spec from implementation
zigmarkdoc src/parser.zig -o spec/parser.md

# Edit spec/parser.md to define desired API...

# After implementation changes, verify match
zigmarkdoc src/parser.zig -o spec/parser.md --check
echo $?  # 0 if implementation matches spec
```

### CI Integration

```yaml
# .github/workflows/docs.yml
- name: Verify parser documentation is current
  run: zigmarkdoc src/parser.zig -o docs/parser.md --check
```

### Minimal Output for LLM Context

```bash
# Signatures only, no code blocks
zigmarkdoc src/parser.zig --no-source --include-private
```

## Development

```bash
# Run tests
zig build test

# Run with debug output
zig build run -- src/example.zig --debug

# Format
zig fmt .
```

## License

MIT

## See Also

- [gomarkdoc](https://github.com/princjef/gomarkdoc) - Go documentation generator
- [spec-driver](https://github.com/...) - Spec-driven development framework
- [std.zig.Ast](https://ziglang.org/documentation/master/std/#std.zig.Ast) - Zig AST documentation