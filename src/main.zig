const std = @import("std");
const TempDir = @import("os/TempDir.zig");

const Action = enum {
    track,
    get,
    get_freeze,
    check_freeze,
};

const ShaCacheKey = struct { repo: []const u8, ref: []const u8 };
const ShaCache = std.HashMap(ShaCacheKey, []const u8, struct {
    pub fn hash(self: @This(), key: ShaCacheKey) u64 {
        _ = self;
        var hasher = std.hash.Wyhash.init(718259503);
        std.hash.autoHashStrat(&hasher, key, .Deep);
        const result = hasher.final();
        return result;
    }

    pub fn eql(self: @This(), a: ShaCacheKey, b: ShaCacheKey) bool {
        _ = self;
        return a.repo.len == b.repo.len and
            a.ref.len == b.ref.len and
            std.mem.eql(u8, a.repo, b.repo) and
            std.mem.eql(u8, a.ref, b.ref);
    }
}, std.hash_map.default_max_load_percentage);

const FileTypeInfo = struct {
    comments: []const []const u8,
    common_indent_width: u8,
};

const file_type_info_map = std.StaticStringMap(FileTypeInfo).initComptime(.{
    .{ ".zig", FileTypeInfo{ .comments = &[_][]const u8{ "//", "///", "//!" }, .common_indent_width = 4 } },
    .{ ".jl", FileTypeInfo{ .comments = &[_][]const u8{ "#", "#=" }, .common_indent_width = 4 } },
    .{ ".js", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".mjs", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".cjs", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".ts", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".tsx", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".jsx", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".py", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 4 } },
    .{ ".java", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".c", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".h", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".cpp", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".cc", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".cxx", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".hpp", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".hh", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".go", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 8 } },
    .{ ".rs", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "///", "//!", "/**", "/*!" }, .common_indent_width = 4 } },
    .{ ".rb", FileTypeInfo{ .comments = &[_][]const u8{ "#", "=begin" }, .common_indent_width = 2 } },
    .{ ".php", FileTypeInfo{ .comments = &[_][]const u8{ "//", "#", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".swift", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "///", "/**" }, .common_indent_width = 4 } },
    .{ ".kt", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".kts", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 4 } },
    .{ ".scala", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "/**" }, .common_indent_width = 2 } },
    .{ ".cs", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "///", "/**" }, .common_indent_width = 4 } },
    .{ ".dart", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "///" }, .common_indent_width = 2 } },
    .{ ".hs", FileTypeInfo{ .comments = &[_][]const u8{ "--", "{-", "{-|" }, .common_indent_width = 2 } },
    .{ ".elm", FileTypeInfo{ .comments = &[_][]const u8{ "--", "{-", "{-|" }, .common_indent_width = 4 } },
    .{ ".purs", FileTypeInfo{ .comments = &[_][]const u8{ "--", "{-" }, .common_indent_width = 2 } },
    .{ ".ml", FileTypeInfo{ .comments = &[_][]const u8{ "(*", "(**" }, .common_indent_width = 2 } },
    .{ ".mli", FileTypeInfo{ .comments = &[_][]const u8{ "(*", "(**" }, .common_indent_width = 2 } },
    .{ ".fs", FileTypeInfo{ .comments = &[_][]const u8{ "//", "(*", "(**", "///" }, .common_indent_width = 4 } },
    .{ ".fsx", FileTypeInfo{ .comments = &[_][]const u8{ "//", "(*", "(**", "///" }, .common_indent_width = 4 } },
    .{ ".lua", FileTypeInfo{ .comments = &[_][]const u8{ "--", "--[[" }, .common_indent_width = 2 } },
    .{ ".r", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".R", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".tex", FileTypeInfo{ .comments = &[_][]const u8{"%"}, .common_indent_width = 2 } },
    .{ ".latex", FileTypeInfo{ .comments = &[_][]const u8{"%"}, .common_indent_width = 2 } },
    .{ ".bib", FileTypeInfo{ .comments = &[_][]const u8{"%"}, .common_indent_width = 2 } },
    .{ ".md", FileTypeInfo{ .comments = &[_][]const u8{"<!--"}, .common_indent_width = 2 } },
    .{ ".markdown", FileTypeInfo{ .comments = &[_][]const u8{"<!--"}, .common_indent_width = 2 } },
    .{ ".rst", FileTypeInfo{ .comments = &[_][]const u8{".."}, .common_indent_width = 2 } },
    .{ ".adoc", FileTypeInfo{ .comments = &[_][]const u8{ "//", "////" }, .common_indent_width = 2 } },
    .{ ".html", FileTypeInfo{ .comments = &[_][]const u8{"<!--"}, .common_indent_width = 2 } },
    .{ ".htm", FileTypeInfo{ .comments = &[_][]const u8{"<!--"}, .common_indent_width = 2 } },
    .{ ".xhtml", FileTypeInfo{ .comments = &[_][]const u8{"<!--"}, .common_indent_width = 2 } },
    .{ ".xml", FileTypeInfo{ .comments = &[_][]const u8{"<!--"}, .common_indent_width = 2 } },
    .{ ".xaml", FileTypeInfo{ .comments = &[_][]const u8{"<!--"}, .common_indent_width = 2 } },
    .{ ".svg", FileTypeInfo{ .comments = &[_][]const u8{"<!--"}, .common_indent_width = 2 } },
    .{ ".css", FileTypeInfo{ .comments = &[_][]const u8{"/*"}, .common_indent_width = 2 } },
    .{ ".scss", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".sass", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".less", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".styl", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".svelte", FileTypeInfo{ .comments = &[_][]const u8{ "<!--", "//", "/*" }, .common_indent_width = 2 } },
    .{ ".vue", FileTypeInfo{ .comments = &[_][]const u8{ "<!--", "//", "/*" }, .common_indent_width = 2 } },
    .{ ".hbs", FileTypeInfo{ .comments = &[_][]const u8{ "{{!--", "{{!" }, .common_indent_width = 2 } },
    .{ ".handlebars", FileTypeInfo{ .comments = &[_][]const u8{ "{{!--", "{{!" }, .common_indent_width = 2 } },
    .{ ".mustache", FileTypeInfo{ .comments = &[_][]const u8{"{{!"}, .common_indent_width = 2 } },
    .{ ".jinja", FileTypeInfo{ .comments = &[_][]const u8{"{#"}, .common_indent_width = 2 } },
    .{ ".j2", FileTypeInfo{ .comments = &[_][]const u8{"{#"}, .common_indent_width = 2 } },
    .{ ".twig", FileTypeInfo{ .comments = &[_][]const u8{"{#"}, .common_indent_width = 2 } },
    .{ ".liquid", FileTypeInfo{ .comments = &[_][]const u8{"{% comment %}"}, .common_indent_width = 2 } },
    .{ ".ejs", FileTypeInfo{ .comments = &[_][]const u8{"<%#"}, .common_indent_width = 2 } },
    .{ ".cshtml", FileTypeInfo{ .comments = &[_][]const u8{ "<!--", "@*" }, .common_indent_width = 2 } },
    .{ ".vbhtml", FileTypeInfo{ .comments = &[_][]const u8{ "<!--", "@*" }, .common_indent_width = 2 } },
    .{ ".json", FileTypeInfo{ .comments = &[_][]const u8{}, .common_indent_width = 2 } },
    .{ ".jsonc", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".yaml", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".yml", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".toml", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".ini", FileTypeInfo{ .comments = &[_][]const u8{ ";", "#" }, .common_indent_width = 2 } },
    .{ ".cfg", FileTypeInfo{ .comments = &[_][]const u8{ "#", ";" }, .common_indent_width = 2 } },
    .{ ".conf", FileTypeInfo{ .comments = &[_][]const u8{ "#", ";" }, .common_indent_width = 2 } },
    .{ ".properties", FileTypeInfo{ .comments = &[_][]const u8{ "#", "!" }, .common_indent_width = 2 } },
    .{ ".editorconfig", FileTypeInfo{ .comments = &[_][]const u8{ ";", "#" }, .common_indent_width = 2 } },
    .{ ".env", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".nginx", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".service", FileTypeInfo{ .comments = &[_][]const u8{ "#", ";" }, .common_indent_width = 2 } },
    .{ ".cmake", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".mk", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 8 } },
    .{ ".mak", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 8 } },
    .{ ".am", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".ps1", FileTypeInfo{ .comments = &[_][]const u8{ "#", "<#" }, .common_indent_width = 4 } },
    .{ ".psm1", FileTypeInfo{ .comments = &[_][]const u8{ "#", "<#" }, .common_indent_width = 4 } },
    .{ ".bat", FileTypeInfo{ .comments = &[_][]const u8{ "REM", "::" }, .common_indent_width = 4 } },
    .{ ".cmd", FileTypeInfo{ .comments = &[_][]const u8{ "REM", "::" }, .common_indent_width = 4 } },
    .{ ".sh", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".bash", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".zsh", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".ksh", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".csh", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".tcsh", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".fish", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".awk", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".sed", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".sql", FileTypeInfo{ .comments = &[_][]const u8{ "--", "/*" }, .common_indent_width = 2 } },
    .{ ".psql", FileTypeInfo{ .comments = &[_][]const u8{ "--", "/*" }, .common_indent_width = 2 } },
    .{ ".proto", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".thrift", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "#" }, .common_indent_width = 2 } },
    .{ ".hcl", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "#" }, .common_indent_width = 2 } },
    .{ ".tf", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "#" }, .common_indent_width = 2 } },
    .{ ".tfvars", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*", "#" }, .common_indent_width = 2 } },
    .{ ".nix", FileTypeInfo{ .comments = &[_][]const u8{ "#", "/*" }, .common_indent_width = 2 } },
    .{ ".gql", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".graphql", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".erl", FileTypeInfo{ .comments = &[_][]const u8{"%"}, .common_indent_width = 4 } },
    .{ ".hrl", FileTypeInfo{ .comments = &[_][]const u8{"%"}, .common_indent_width = 4 } },
    .{ ".ex", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".exs", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".clj", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 2 } },
    .{ ".cljs", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 2 } },
    .{ ".cljc", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 2 } },
    .{ ".edn", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 2 } },
    .{ ".el", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 2 } },
    .{ ".lisp", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 2 } },
    .{ ".scm", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 2 } },
    .{ ".rkt", FileTypeInfo{ .comments = &[_][]const u8{ ";", "#|" }, .common_indent_width = 2 } },
    .{ ".asm", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 4 } },
    .{ ".s", FileTypeInfo{ .comments = &[_][]const u8{";"}, .common_indent_width = 4 } },
    .{ ".v", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".sv", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
    .{ ".vhdl", FileTypeInfo{ .comments = &[_][]const u8{"--"}, .common_indent_width = 2 } },
    .{ ".vhd", FileTypeInfo{ .comments = &[_][]const u8{"--"}, .common_indent_width = 2 } },
    .{ ".glsl", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 4 } },
    .{ ".vert", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 4 } },
    .{ ".frag", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 4 } },
    .{ ".wgsl", FileTypeInfo{ .comments = &[_][]const u8{"//"}, .common_indent_width = 4 } },
    .{ ".gradle", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 4 } },
    .{ ".groovy", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 4 } },
    .{ ".nim", FileTypeInfo{ .comments = &[_][]const u8{ "#", "#[" }, .common_indent_width = 2 } },
    .{ ".po", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".pot", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".http", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 2 } },
    .{ ".proto3", FileTypeInfo{ .comments = &[_][]const u8{ "//", "/*" }, .common_indent_width = 2 } },
});

fn recursivelyUpdate(
    arena: *std.heap.ArenaAllocator,
    temp_dir: *TempDir,
    sha_cache: *ShaCache,
    parent_dir: std.fs.Dir,
    name: []const u8,
    kind: std.fs.File.Kind,
) !void {
    if (kind == .directory) {
        if (name.len > 1 and name[0] == '.') return;

        var dir = try parent_dir.openDir(name, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            try recursivelyUpdate(arena, temp_dir, sha_cache, dir, entry.name, entry.kind);
        }
    } else if (kind == .file) {
        try updateFile(arena, temp_dir, sha_cache, parent_dir, name);
    }
}

fn updateFile(
    arena: *std.heap.ArenaAllocator,
    temp_dir: *TempDir,
    sha_cache: *ShaCache,
    dir: std.fs.Dir,
    file_name: []const u8,
) !void {
    const ext = std.fs.path.extension(file_name);
    const file_type_info = file_type_info_map.get(ext) orelse return;

    const allocator = arena.allocator();
    defer _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 });
    var file = try dir.openFile(file_name, .{});
    errdefer file.close(); // also closed below
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);
    var reader = &file_reader.interface;
    const bytes = try reader.allocRemaining(allocator, .unlimited);
    file.close();
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var line_number: usize = 1;
    var has_update = false;
    var has_conflicts = false;

    var updated_bytes = try std.ArrayList(u8).initCapacity(allocator, bytes.len + 1024);
    var indent: ?Indent = null;

    while (lines.next()) |line| : (line_number += 1) {
        if (mightMatchTag(line)) {
            switch (try updateChunk(
                allocator,
                temp_dir,
                sha_cache,
                file_name,
                line_number,
                &updated_bytes,
                &lines,
                line,
                &indent,
                file_type_info,
            )) {
                .updated => {
                    has_update = true;
                },
                .updated_with_conflicts => {
                    has_update = true;
                    has_conflicts = true;
                },
                .untouched => {},
                .not_a_chunk => {
                    try updated_bytes.appendSlice(allocator, line);
                    try maybeAppendNewline(allocator, &updated_bytes, &lines);
                },
            }
        } else {
            try updated_bytes.appendSlice(allocator, line);
            try maybeAppendNewline(allocator, &updated_bytes, &lines);
        }
    }

    if (has_update) {
        try dir.writeFile(.{ .sub_path = file_name, .data = updated_bytes.items });
    }
    if (has_conflicts) {
        const prefix_result = try std.process.Child.run(.{
            .allocator = allocator,
            .cwd_dir = dir,
            .argv = &.{ "git", "rev-parse", "--show-prefix" },
        });
        const prefix = std.mem.trimRight(u8, prefix_result.stdout, &std.ascii.whitespace);
        const git_path = try std.fs.path.join(allocator, &.{ prefix, file_name });
        std.debug.print("File has conflicts: {s}\n", .{git_path});
    }
}

fn maybeAppendNewline(
    allocator: std.mem.Allocator,
    bytes: *std.ArrayList(u8),
    lines: *std.mem.SplitIterator(u8, .scalar),
) !void {
    if (lines.peek() != null) {
        try bytes.append(allocator, '\n');
    }
}

const copyv_tag = "copyv:";

fn mightMatchTag(line: []const u8) bool {
    return std.mem.indexOf(u8, line, copyv_tag) != null;
}

const Match = struct {
    prefix: []const u8,
    indent: Indent,
};

const Indent = struct {
    // This is pre-multiplied with `width` (or even allows non-width aligned starting indents)
    start: usize,

    width: usize,
    char: u8, // ' ' or '\t'
};

const line_whitespace = " \t";

fn matchesTag(
    line: []const u8,
    file_type_info: FileTypeInfo,
    lazy_file_indent: *?Indent,
    file_bytes: []const u8,
) ?Match {
    const line_trimmed = std.mem.trimStart(u8, line, line_whitespace);
    for (file_type_info.comments) |comment| {
        if (std.mem.startsWith(u8, line_trimmed, comment)) {
            const tag = line_trimmed[comment.len..];
            const tag_trimmed = std.mem.trimStart(u8, tag, line_whitespace);
            if (std.mem.startsWith(u8, tag_trimmed, copyv_tag)) {
                const comment_start = line.len - line_trimmed.len;
                const tag_whitespace = tag.len - tag_trimmed.len;
                const prefix_len = comment_start + comment.len + tag_whitespace + copyv_tag.len;
                const prefix = line[0..prefix_len];
                const file_indent = lazy_file_indent.* orelse blk: {
                    const indent = getIndent(file_bytes, file_type_info.common_indent_width);
                    lazy_file_indent.* = indent;
                    break :blk indent;
                };

                return .{
                    .prefix = prefix,
                    .indent = .{
                        .start = getIndentStart(
                            line[0..comment_start],
                            file_indent.width,
                            file_indent.char,
                        ),
                        .width = file_indent.width,
                        .char = file_indent.char,
                    },
                };
            }
        }
    }

    return null;
}

fn appendEndTag(
    allocator: std.mem.Allocator,
    updated_bytes: *std.ArrayList(u8),
    indent: Indent,
    file_type_info: FileTypeInfo,
) !void {
    var whitespace: []const u8 = undefined;

    if (indent.char == ' ') {
        whitespace = try getWhitespace(
            allocator,
            ' ',
            indent.start,
        );
    } else {
        const num_tabs = indent.start / indent.width;
        const num_spaces = indent.start - indent.start % indent.width;
        whitespace = try getMixedWhitespace(
            allocator,
            num_tabs,
            num_spaces,
        );
    }

    try updated_bytes.appendSlice(allocator, whitespace);
    try updated_bytes.appendSlice(allocator, file_type_info.comments[0]);
    try updated_bytes.appendSlice(allocator, " copyv: end");
}

const ChunkStatus = enum {
    updated,
    updated_with_conflicts,
    untouched,
    not_a_chunk,
};

fn updateChunk(
    allocator: std.mem.Allocator,
    temp_dir: *TempDir,
    sha_cache: *ShaCache,
    file_name: []const u8,
    start_line_number: usize,
    updated_bytes: *std.ArrayList(u8),
    lines: *std.mem.SplitIterator(u8, .scalar),
    current_line: []const u8,
    lazy_file_indent: *?Indent,
    file_type_info: FileTypeInfo,
) !ChunkStatus {
    // Check if matches tag
    const maybe_match = matchesTag(
        current_line,
        file_type_info,
        lazy_file_indent,
        lines.buffer,
    );

    if (maybe_match == null) {
        return .not_a_chunk;
    }

    const match = maybe_match.?;
    const prefix = match.prefix;
    const indent = match.indent;

    // Get the files from remote

    const line_payload = std.mem.trim(u8, current_line[prefix.len..], line_whitespace);
    var line_args = std.mem.splitScalar(u8, line_payload, ' ');
    const first_arg = line_args.first();
    var action: Action = undefined;
    var url_with_line_numbers: []const u8 = undefined;

    if (std.mem.eql(u8, first_arg, "track")) {
        action = .track;
        url_with_line_numbers = line_args.rest();
    } else if (std.mem.eql(u8, first_arg, "freeze")) {
        action = .check_freeze;
        url_with_line_numbers = line_args.rest();
    } else if (std.mem.eql(u8, first_arg, "end")) {
        std.debug.panic(
            "{s}[{d}]: Unexpected 'copyv: end' outside of a copyv chunk\n",
            .{ file_name, start_line_number },
        );
    } else { // get
        if (std.mem.startsWith(u8, first_arg, "g")) { // get
            if (line_args.peek()) |peek| {
                if (std.mem.startsWith(u8, peek, "fr")) { // freeze
                    action = .get_freeze;
                    _ = line_args.next(); // skip fr[eeze]
                } else {
                    action = .get;
                }
            } else {
                std.debug.panic("{s}[{d}]: Expected an argument after get\n", .{
                    file_name,
                    start_line_number,
                });
            }
            url_with_line_numbers = line_args.rest();
        } else if (std.mem.startsWith(u8, first_arg, "http")) {
            action = .get;
            url_with_line_numbers = first_arg;
        } else {
            std.debug.panic("{s}[{d}]: Unknown action: {s}\n", .{
                file_name,
                start_line_number,
                first_arg,
            });
        }
    }

    var url_parts = std.mem.splitScalar(u8, url_with_line_numbers, '#');
    const original_url = url_parts.next().?;
    const line_numbers_str = url_parts.rest();
    var blob_it = std.mem.splitSequence(u8, original_url, "/blob/");
    const original_host = blob_it.next().?;
    const ref_with_path = blob_it.next().?;
    var path_parts = std.mem.splitScalar(u8, ref_with_path, '/');
    const ref = path_parts.next().?;

    if (action == .check_freeze) {
        if (ref.len != 40) {
            std.debug.panic(
                "{s}[{d}]: 'copyv: freeze' line must point to a commit SHA\n",
                .{ file_name, start_line_number },
            );
        }

        const current_start = current_line.ptr - lines.buffer.ptr;
        const end_line = skipToEndLine(
            lines,
            indent,
            file_type_info,
            file_name,
            start_line_number,
        );
        const current_end = end_line.ptr - lines.buffer.ptr + end_line.len;
        try updated_bytes.appendSlice(
            allocator,
            lines.buffer[current_start..current_end],
        );
        try maybeAppendNewline(allocator, updated_bytes, lines);

        return .untouched;
    }

    const path = path_parts.rest();
    const repo = original_host["https://github.com/".len..];
    var line_numbers = std.mem.splitScalar(u8, line_numbers_str, '-');
    const base_start_str = line_numbers.next().?["L".len..];
    const base_start = try std.fmt.parseInt(usize, base_start_str, 10);
    var base_end: usize = undefined;
    if (line_numbers.next()) |end_str| {
        const base_end_str = end_str["L".len..];
        base_end = try std.fmt.parseInt(usize, base_end_str, 10);
    } else {
        base_end = base_start;
    }

    const base_sha = if (ref.len == 40)
        ref
    else
        try fetchLatestCommitSha(allocator, sha_cache, repo, ref);
    const base_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}", .{ repo, ref_with_path });
    const base_file_bytes = try fetchFile(allocator, base_url);

    if (action == .get_freeze) {
        const base_bytes = try getLines(base_file_bytes, base_start, base_end);
        const updated_line = try std.fmt.allocPrint(
            allocator,
            "{s} freeze {s}/blob/{s}/{s}#{s}",
            .{ prefix, original_host, base_sha, path, line_numbers_str },
        );
        try updated_bytes.appendSlice(allocator, updated_line);
        try updated_bytes.append(allocator, '\n');
        try matchIndent(
            allocator,
            updated_bytes,
            base_bytes,
            indent,
            file_type_info.common_indent_width,
        );
        try updated_bytes.append(allocator, '\n');
        try appendEndTag(allocator, updated_bytes, indent, file_type_info);
        try maybeAppendNewline(allocator, updated_bytes, lines);

        return .updated;
    }

    const new_sha = if (ref.len == 40)
        try fetchLatestCommitSha(allocator, sha_cache, repo, "HEAD")
    else
        base_sha;
    var new_file_bytes: []const u8 = undefined;
    if (std.mem.eql(u8, base_sha, new_sha)) {
        new_file_bytes = base_file_bytes;
    } else {
        const new_url = try std.fmt.allocPrint(
            allocator,
            "https://raw.githubusercontent.com/{s}/{s}/{s}",
            .{ repo, new_sha, path },
        );
        new_file_bytes = try fetchFile(allocator, new_url);
    }

    // Diff the files

    try temp_dir.dir.writeFile(.{ .sub_path = "base", .data = base_file_bytes });
    try temp_dir.dir.writeFile(.{ .sub_path = "new", .data = new_file_bytes });
    var base_file_name_buffer: [1024]u8 = undefined;
    var new_file_name_buffer: [1024]u8 = undefined;
    const base_file_name = try temp_dir.dir.realpath("base", &base_file_name_buffer);
    const new_file_name = try temp_dir.dir.realpath("new", &new_file_name_buffer);

    const diff_result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "diff", "--no-index", base_file_name, new_file_name },
    });

    // Check if diff is in the chunk

    var diff_lines = std.mem.splitScalar(u8, diff_result.stdout, '\n');
    var base_line: usize = 0;
    var new_line: usize = 0;
    var new_start: usize = 0;
    var new_end: usize = 0;
    var base_range: GitRange = .{ .start = 0, .len = 0 };
    var new_range: GitRange = .{ .start = 0, .len = 0 };
    var has_diff_in_chunk = false;
    var last_diff_delta: isize = 0;

    for (0..4) |_| _ = diff_lines.next(); // Skip diff header

    while (diff_lines.next()) |diff_line| {
        if (std.mem.startsWith(u8, diff_line, "@@")) {
            std.debug.assert(base_line == base_range.start + base_range.len);
            std.debug.assert(new_line == new_range.start + new_range.len);
            var header_parts = std.mem.splitScalar(u8, diff_line, ' ');
            _ = header_parts.next().?; // skip @@
            base_range = try parseRange(header_parts.next().?);
            new_range = try parseRange(header_parts.next().?);
            base_line = base_range.start;
            new_line = new_range.start;
            last_diff_delta = @as(isize, @intCast(base_range.start)) - @as(isize, @intCast(new_range.start));
            const base_range_end = base_range.start + base_range.len;

            if ((base_line <= base_start and base_end <= base_range_end) or
                (base_start <= base_line and base_range_end <= base_end) or
                (base_line < base_start and base_start < base_range_end) or
                (base_start < base_line and base_line < base_end))
            {
                has_diff_in_chunk = true;
            }

            if (new_start == 0 and base_line > base_start) {
                const delta: usize = base_line - base_start;
                new_start = new_line - delta;
            }
            if (new_end == 0 and base_line > base_end) {
                const delta: usize = base_line - base_end;
                new_end = new_line - delta;
            }
        } else if (std.mem.startsWith(u8, diff_line, "-")) {
            base_line += 1;
        } else if (std.mem.startsWith(u8, diff_line, "+")) {
            new_line += 1;
        } else {
            // Either it's a shared line or the last empty line of the diff
            std.debug.assert(std.mem.startsWith(u8, diff_line, " ") or diff_lines.peek() == null);
            base_line += 1;
            new_line += 1;
        }

        if (base_line == base_start and new_start == 0) {
            new_start = new_line;
        }
        if (base_line == base_end) {
            new_end = new_line;
        }
    }

    if (has_diff_in_chunk) {
        // We've at least set the start because the diff affected the chunk
        std.debug.assert(new_start != 0);

        if (new_end == 0) {
            // The only diffs were before the end of this chunk
            std.debug.assert(base_line < base_end);
            const delta: isize = @intCast(new_line - base_line);
            new_end = @intCast(@as(isize, @intCast(base_end)) + delta);
        }
    } else {
        // None of the diffs affected the chunk

        if (new_start == 0) {
            std.debug.assert(new_end == 0);
            new_start = @intCast(@as(isize, @intCast(base_start)) + last_diff_delta);
            new_end = @intCast(@as(isize, @intCast(base_end)) + last_diff_delta);
        } else {
            std.debug.assert(new_end - new_start == base_end - base_start);
        }
    }

    // Write base and new files

    const base_bytes = try getLines(base_file_bytes, base_start, base_end);
    const new_bytes = try getLines(new_file_bytes, new_start, new_end);
    var base_indented = try std.ArrayList(u8).initCapacity(allocator, base_bytes.len);
    var new_indented = try std.ArrayList(u8).initCapacity(allocator, new_bytes.len);
    try matchIndent(
        allocator,
        &base_indented,
        base_bytes,
        indent,
        file_type_info.common_indent_width,
    );
    try matchIndent(
        allocator,
        &new_indented,
        new_bytes,
        indent,
        file_type_info.common_indent_width,
    );
    try temp_dir.dir.writeFile(.{ .sub_path = "base", .data = base_indented.items });
    try temp_dir.dir.writeFile(.{ .sub_path = "new", .data = new_indented.items });

    var updated_chunk: []const u8 = new_indented.items;
    var has_conflicts = false;

    // Get the current chunk
    if (action == .track) {
        const current_bytes = lines.buffer;
        const current_start = current_line.ptr - current_bytes.ptr + current_line.len + 1;
        const end_line = skipToEndLine(
            lines,
            indent,
            file_type_info,
            file_name,
            start_line_number,
        );
        const current_end = end_line.ptr - lines.buffer.ptr - 1;

        // Determine updated chunk bytes

        const current_chunk = current_bytes[current_start..current_end];
        if (!std.mem.eql(u8, current_chunk, base_indented.items)) {
            try temp_dir.dir.writeFile(.{ .sub_path = "current", .data = current_chunk });
            var current_file_name_buffer: [1024]u8 = undefined;
            const current_file_name = try temp_dir.dir.realpath(
                "current",
                &current_file_name_buffer,
            );

            const config_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "config", "--get", "merge.conflictstyle" },
            });
            const conflict_style = std.mem.trim(u8, config_result.stdout, line_whitespace);
            var merge_args = try std.ArrayList([]const u8).initCapacity(allocator, 12);
            merge_args.appendSliceAssumeCapacity(
                &[_][]const u8{ "git", "merge-file", "-p", "-L", "ours" },
            );

            if (std.mem.eql(u8, conflict_style, "diff3")) {
                merge_args.appendSliceAssumeCapacity(
                    &[_][]const u8{ "-L", "base", "--diff3" },
                );
            } else if (std.mem.eql(u8, conflict_style, "zdiff3")) {
                merge_args.appendSliceAssumeCapacity(
                    &[_][]const u8{ "-L", "base", "--zdiff3" },
                );
            } else {
                merge_args.appendSliceAssumeCapacity(
                    &[_][]const u8{ "-L", "base" },
                );
            }

            merge_args.appendSliceAssumeCapacity(&[_][]const u8{
                "-L",
                "theirs",
                current_file_name,
                base_file_name,
                new_file_name,
            });

            const merge_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = merge_args.items,
            });
            updated_chunk = merge_result.stdout;

            switch (merge_result.term) {
                .Exited => |code| {
                    if (code >= 127) {
                        std.debug.panic("{s}[{d}]: Unexpected merge result error code: {d}\n", .{
                            file_name,
                            start_line_number,
                            code,
                        });
                    } else if (code != 0) {
                        has_conflicts = true;
                    }
                },
                else => {
                    std.debug.panic("{s}[{d}]: Unexpected merge result term\n", .{
                        file_name,
                        start_line_number,
                    });
                },
            }
        }
    }

    // Write back bytes

    const updated_url = try std.fmt.allocPrint(
        allocator,
        "{s} track {s}/blob/{s}/{s}#L{d}-L{d}",
        .{ prefix, original_host, new_sha, path, new_start, new_end },
    );
    try updated_bytes.appendSlice(allocator, updated_url);
    try updated_bytes.append(allocator, '\n');
    try updated_bytes.appendSlice(allocator, updated_chunk);
    try updated_bytes.append(allocator, '\n');
    try appendEndTag(allocator, updated_bytes, indent, file_type_info);
    try maybeAppendNewline(allocator, updated_bytes, lines);

    if (has_conflicts) {
        return .updated_with_conflicts;
    } else {
        return .updated;
    }
}

const GitRange = struct {
    start: usize,
    len: usize,
};

fn parseRange(range_str: []const u8) !GitRange {
    var parts = std.mem.splitScalar(u8, range_str, ',');
    const start_str = parts.next().?;
    const start = try std.fmt.parseInt(usize, start_str[1..], 10);
    const len_str = parts.next().?;
    const len = try std.fmt.parseInt(usize, len_str, 10);
    return .{ .start = start, .len = len };
}

const max_output_bytes = 100_000_000;

fn fetchLatestCommitSha(
    allocator: std.mem.Allocator,
    sha_cache: *ShaCache,
    repo: []const u8,
    ref: []const u8,
) ![]const u8 {
    const cache_key: ShaCacheKey = .{ .repo = repo, .ref = ref };

    const gop = try sha_cache.getOrPut(cache_key);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }

    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/commits/{s}", .{ repo, ref });

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    var client = std.http.Client{ .allocator = allocator };

    var authorization: std.http.Client.Request.Headers.Value = undefined;

    if (std.process.hasEnvVarConstant("GITHUB_TOKEN")) {
        const token = try std.process.getEnvVarOwned(allocator, "GITHUB_TOKEN");
        const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        authorization = .{ .override = auth_value };
    } else {
        authorization = .default;
    }

    const result = try client.fetch(.{
        .location = .{ .url = api_url },
        .response_writer = &aw.writer,
        .headers = .{
            .authorization = authorization,
        },
    });

    if (result.status == .forbidden or result.status == .too_many_requests) {
        std.debug.print("GitHub API rate limit exceeded. Try again later or authenticate.\n", .{});
        return error.RateLimited;
    }

    const json_bytes = try aw.toOwnedSlice();
    defer allocator.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const sha = parsed.value.object.get("sha") orelse {
        std.debug.print("GitHub API error (status {d}): {s}\n", .{ @intFromEnum(result.status), json_bytes });
        return error.GitHubApiError;
    };

    const cache_allocator = sha_cache.allocator;
    gop.key_ptr.* = .{
        .repo = try cache_allocator.dupe(u8, repo),
        .ref = try cache_allocator.dupe(u8, ref),
    };
    const sha_owned = try cache_allocator.dupe(u8, sha.string);
    gop.value_ptr.* = sha_owned;
    return sha_owned;
}

fn fetchFile(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    var client = std.http.Client{ .allocator = allocator };
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });

    return try aw.toOwnedSlice();
}

fn getLines(bytes: []const u8, start_line: usize, end_line: usize) ![]const u8 {
    var start: usize = undefined;
    var end: usize = undefined;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var i: usize = 1;

    while (lines.next()) |line| : (i += 1) {
        if (i == start_line) {
            start = line.ptr - bytes.ptr;
        }
        if (i == end_line) {
            end = line.ptr - bytes.ptr + line.len;
        }
    }

    return bytes[start..end];
}

fn skipToEndLine(
    lines: *std.mem.SplitIterator(u8, .scalar),
    indent: Indent,
    file_type_info: FileTypeInfo,
    file_name: []const u8,
    start_line_number: usize,
) []const u8 {
    var line_number = start_line_number;
    var file_indent: ?Indent = indent;
    var nesting: usize = 0;

    return while (lines.next()) |line| : (line_number += 1) {
        if (!mightMatchTag(line)) continue;

        const match = matchesTag(line, file_type_info, &file_indent, "");
        if (match == null or match.?.indent.start != indent.start) continue;

        const line_payload = std.mem.trim(u8, line[match.?.prefix.len..], line_whitespace);
        var line_args = std.mem.splitScalar(u8, line_payload, ' ');
        const first_arg = line_args.first();

        if (std.mem.startsWith(u8, first_arg, "end")) {
            if (nesting == 0) {
                break line;
            }

            nesting -= 1;
        } else if (std.mem.startsWith(u8, first_arg, "fr") or // "freeze"
            std.mem.startsWith(u8, first_arg, "tr") // "track"
        ) {
            nesting += 1;
        }
    } else {
        std.debug.panic(
            "{s}[{d}]: Expected copyv: end, but instead reached end of file\n",
            .{
                file_name,
                line_number,
            },
        );
    };
}

const shift_count_threshold = 8;
const space_count_threshold = 5;
const tab_count_threshold = 3;
const max_indent_width = 16;

fn getIndentStart(
    whitespace: []const u8,
    file_type_common_indent: usize,
    indent_char: u8,
) usize {
    if (indent_char == ' ') {
        return whitespace.len;
    } else {
        const tab_count = std.mem.count(u8, whitespace, "\t");
        const space_count = std.mem.count(u8, whitespace, " ");

        // Note: this does not consider spaces that have no impact on
        // the indentation because they are followed by tabs, but for
        // well-formed whitespace, that shouldn't be the case.
        return tab_count * file_type_common_indent + space_count;
    }
}

fn getIndent(bytes: []const u8, file_type_common_indent: usize) Indent {
    var space_count: usize = 0;
    var tab_count: usize = 0;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const char: u8 = while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, " ")) {
            space_count += 1;
            if (space_count >= space_count_threshold) {
                break ' ';
            }
        } else if (std.mem.startsWith(u8, line, "\t")) {
            tab_count += 1;
            if (tab_count >= tab_count_threshold) {
                break '\t';
            }
        }
    } else if (tab_count >= space_count and tab_count > 0) '\t' else ' ';

    lines = std.mem.splitScalar(u8, bytes, '\n');
    const start = while (lines.next()) |line| {
        const first_non_whitespace = std.mem.indexOfNone(u8, line, line_whitespace);
        if (first_non_whitespace) |index| {
            break getIndentStart(line[0..index], file_type_common_indent, char);
        }
    } else 0;

    if (char == '\t') {
        return .{
            .start = start,
            .width = file_type_common_indent,
            .char = char,
        };
    }

    var shift_counts: [max_indent_width]usize = @splat(0);

    // bias shift counts towards expected indents as a prior
    shift_counts[2] = 2;
    shift_counts[4] = 2;
    shift_counts[file_type_common_indent] += 1;

    var last_indent: usize = 0;
    lines = std.mem.splitScalar(u8, bytes, '\n');
    const width = while (lines.next()) |line| {
        const first_non_whitespace = std.mem.indexOfNone(u8, line, line_whitespace);
        if (first_non_whitespace) |index| {
            if (index != last_indent) {
                const shift = @abs(@as(isize, @intCast(index)) -
                    @as(isize, @intCast(last_indent)));
                if (shift < shift_counts.len) {
                    shift_counts[shift] += 1;
                    if (shift_counts[shift] >= shift_count_threshold) {
                        break shift;
                    }
                }

                last_indent = index;
            }
        }
    } else blk: {
        var shift: usize = 0;
        var max_count: usize = 0;
        for (shift_counts, 0..) |count, i| {
            if (count > max_count) {
                max_count = count;
                shift = i;
            }
        }

        break :blk shift;
    };

    return .{
        .start = start,
        .width = width,
        .char = char,
    };
}

const max_easy_whitespace_len = 64 - max_indent_width;
const tabs_followed_by_spaces: [max_easy_whitespace_len + max_indent_width]u8 =
    @as([max_easy_whitespace_len]u8, @splat('\t')) ++
    @as([max_indent_width]u8, @splat(' '));
const spaces: [max_easy_whitespace_len]u8 = @splat(' ');

fn getWhitespace(allocator: std.mem.Allocator, char: u8, len: usize) ![]const u8 {
    if (len <= max_easy_whitespace_len) {
        return if (char == ' ') spaces[0..len] else tabs_followed_by_spaces[0..len];
    } else {
        const whitespace = try allocator.alloc(u8, len);
        @memset(whitespace, char);
        return whitespace;
    }
}

fn getMixedWhitespace(allocator: std.mem.Allocator, tab_count: usize, space_count: usize) ![]const u8 {
    if (space_count <= max_indent_width and tab_count <= max_easy_whitespace_len) {
        return tabs_followed_by_spaces[max_easy_whitespace_len - tab_count .. max_easy_whitespace_len + space_count];
    } else {
        const whitespace = try allocator.alloc(u8, space_count + tab_count);
        @memset(whitespace[0..tab_count], '\t');
        @memset(whitespace[tab_count..], ' ');
        return whitespace;
    }
}

fn matchIndent(
    allocator: std.mem.Allocator,
    updated_bytes: *std.ArrayList(u8),
    bytes: []const u8,
    desired: Indent,
    file_type_common_indent: usize,
) !void {
    const current = getIndent(bytes, file_type_common_indent);

    // Fast path for equal indents
    if (current.width == desired.width and
        current.start == desired.start and
        current.char == desired.char)
    {
        try updated_bytes.appendSlice(allocator, bytes);
        return;
    }

    // Simpler path for consistent indents (same char and for spaces same width,
    // or for tabs, starts that are aligned with the widths)
    if (current.char == desired.char and
        ((desired.char == ' ' and current.width == desired.width) or (desired.char == '\t' and
            current.start % current.width == 0 and
            desired.start % desired.width == 0)))
    {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var desired_start: usize = undefined;
        var current_start: usize = undefined;
        if (desired.char == '\t') {
            desired_start = desired.start / desired.width;
            current_start = current.start / current.width;
        } else {
            desired_start = desired.start;
            current_start = current.start;
        }
        if (desired_start > current_start) {
            const add = desired_start - current_start;
            const add_bytes = try getWhitespace(allocator, desired.char, add);
            while (lines.next()) |line| {
                const line_start = std.mem.indexOfNone(u8, line, line_whitespace) orelse line.len;
                if (line_start > 0 or (line.len > 0 and current.start == 0)) {
                    try updated_bytes.appendSlice(allocator, add_bytes);
                }
                // This will leave whitespace in whitespace-only lines
                try updated_bytes.appendSlice(allocator, line);
                if (lines.peek() != null) {
                    try updated_bytes.append(allocator, '\n');
                }
            }
        } else {
            const remove = current_start - desired_start;
            while (lines.next()) |line| {
                const start = @min(
                    remove,
                    std.mem.indexOfNone(u8, line, line_whitespace) orelse line.len,
                );
                // This will leave whitespace in whitespace-only lines
                try updated_bytes.appendSlice(allocator, line[start..]);
                if (lines.peek() != null) {
                    try updated_bytes.append(allocator, '\n');
                }
            }
        }

        return;
    }

    // Complex path for mixed indents
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var desired_tabs: usize = undefined;
    var desired_spaces: usize = undefined;
    var desired_whitespace: []const u8 = undefined;

    if (desired.char == ' ') {
        desired_spaces = desired.start;
        desired_whitespace = try getWhitespace(
            allocator,
            ' ',
            desired_spaces,
        );
    } else {
        desired_tabs = desired.start / desired.width;
        desired_spaces = desired.start - desired.start % desired.width;
        desired_whitespace = try getMixedWhitespace(
            allocator,
            desired_tabs,
            desired_spaces,
        );
    }

    while (lines.next()) |line| {
        const line_start = std.mem.indexOfNone(u8, line, line_whitespace) orelse line.len;
        const tab_count = std.mem.count(u8, line[0..line_start], "\t");
        const space_count = std.mem.count(u8, line[0..line_start], " ");

        // Note: this does not consider spaces that have no impact on
        // the indentation because they are followed by tabs, but for
        // well-formed whitespace, that shouldn't be the case.
        const line_width = tab_count * current.width + space_count;
        var whitespace: []const u8 = undefined;

        if (line_width > current.start) {
            const over_start = line_width - current.start;
            const over_indents = over_start / current.width;
            const over_spaces = over_start - over_indents * current.width;
            whitespace = if (desired.char == ' ')
                try getWhitespace(
                    allocator,
                    ' ',
                    desired_spaces + over_indents * desired.width + over_spaces,
                )
            else
                try getMixedWhitespace(allocator, desired_tabs + over_indents, desired_spaces + over_spaces);
        } else {
            whitespace = desired_whitespace;
        }

        if (line_start > 0 or (line.len > 0 and current.start == 0)) {
            // This will leave whitespace in whitespace-only lines
            try updated_bytes.appendSlice(allocator, whitespace);
        }
        try updated_bytes.appendSlice(allocator, line[line_start..]);

        if (lines.peek() != null) {
            try updated_bytes.append(allocator, '\n');
        }
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var temp_dir = try TempDir.init();
    defer temp_dir.deinit();

    const allocator = arena.allocator();

    var sha_cache = ShaCache.init(std.heap.page_allocator);
    defer sha_cache.deinit();

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.next();

    var name: []const u8 = ".";
    var kind: std.fs.File.Kind = .directory;
    if (arg_it.next()) |path| {
        name = path;
        const stat = try std.fs.cwd().statFile(path);
        kind = stat.kind;
    }

    try recursivelyUpdate(&arena, &temp_dir, &sha_cache, std.fs.cwd(), name, kind);
}
