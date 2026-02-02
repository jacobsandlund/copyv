const std = @import("std");

const Action = enum {
    track,
    get,
    get_freeze,
    check_freeze,
};

const Platform = enum {
    github,
    gitlab,
    codeberg,

    fn parse(host: []const u8) !Platform {
        if (std.mem.eql(u8, host, "github.com")) return .github;
        if (std.mem.eql(u8, host, "gitlab.com")) return .gitlab;
        if (std.mem.eql(u8, host, "codeberg.org")) return .codeberg;
        return error.UnknownPlatform;
    }
};

const PlatformFilter = packed struct {
    github: bool = true,
    gitlab: bool = true,
    codeberg: bool = true,

    const blacklist_default = PlatformFilter{};
    const whitelist_default = PlatformFilter{ .github = false, .gitlab = false, .codeberg = false };

    fn isEnabled(self: PlatformFilter, platform: Platform) bool {
        return switch (platform) {
            inline else => |tag| {
                return @field(self, @tagName(tag));
            },
        };
    }

    fn setPlatform(self: *PlatformFilter, platform: Platform, enabled: bool) void {
        switch (platform) {
            inline else => |tag| {
                @field(self, @tagName(tag)) = enabled;
            },
        }
    }
};

const GlobalContext = struct {
    arena: *std.heap.ArenaAllocator,
    cache_dir: std.fs.Dir,
    sha_cache: *ShaCache,
    platform_filter: PlatformFilter,
    debug_indent: bool = false,
};

const ShaCacheKey = struct { platform: Platform, repo: []const u8, ref: []const u8 };
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
        return a.platform == b.platform and
            a.repo.len == b.repo.len and
            a.ref.len == b.ref.len and
            std.mem.eql(u8, a.repo, b.repo) and
            std.mem.eql(u8, a.ref, b.ref);
    }
}, std.hash_map.default_max_load_percentage);

const Comment = union(enum) {
    line: []const u8,
    paired: struct {
        begin: []const u8,
        end: []const u8,
    },
};

const FileTypeIndentDefault = struct { width: u8, char: u8 };
const FileTypeIndent = union(enum) {
    default: FileTypeIndentDefault,
    off,
};

const FileTypeInfo = struct {
    comments: []const Comment,
    indent: FileTypeIndent,
};

const text_file_type_info = FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .off };

const file_type_info_map = std.StaticStringMap(FileTypeInfo).initComptime(.{
    .{ ".4th", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "\\" }, .{ .paired = .{ .begin = "(", .end = ")" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".R", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".adb", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "--" }}, .indent = .{ .default = .{ .width = 3, .char = ' ' } } } },
    .{ ".adoc", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .line = "////" } }, .indent = .off } },
    .{ ".ads", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "--" }}, .indent = .{ .default = .{ .width = 3, .char = ' ' } } } },
    .{ ".am", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".asm", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".awk", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".bash", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".bas", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "'" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".bat", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "REM" }, .{ .line = "::" } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".bib", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "%" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".bqn", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".bzl", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".c", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cc", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cfg", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .line = ";" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cjs", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".clj", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cljc", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cljs", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cls", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "'" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".cmake", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cmd", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "REM" }, .{ .line = "::" } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".conf", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .line = ";" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".containerfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cpp", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cs", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "///" }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".csh", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cshtml", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "<!--", .end = "-->" } }, .{ .paired = .{ .begin = "@*", .end = "*@" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".css", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "/*", .end = "*/" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".cxx", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".dart", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "///" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".dat", text_file_type_info },
    .{ ".def", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".dockerfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".editorconfig", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = ";" }, .{ .line = "#" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".edn", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".ejs", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<%#", .end = "%>" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".el", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".elm", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "--" }, .{ .paired = .{ .begin = "{-", .end = "-}" } }, .{ .paired = .{ .begin = "{-|", .end = "-}" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".env", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".erl", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "%" }, .{ .line = "%%" } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".ex", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".exs", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".factor", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "!" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".fish", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".forth", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "\\" }, .{ .paired = .{ .begin = "(", .end = ")" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".frag", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".frm", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "'" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".fs", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "(*", .end = "*)" } }, .{ .paired = .{ .begin = "(**", .end = "*)" } }, .{ .line = "///" } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".fsl", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".fsx", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "(*", .end = "*)" } }, .{ .paired = .{ .begin = "(**", .end = "*)" } }, .{ .line = "///" } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".fsy", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".fth", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "\\" }, .{ .paired = .{ .begin = "(", .end = ")" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".g4", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".glsl", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".go", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
    .{ ".gql", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".gradle", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".graphql", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".groovy", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".h", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".handlebars", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "{{!--", .end = "--}}" } }, .{ .paired = .{ .begin = "{{!", .end = "}}" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".hbs", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "{{!--", .end = "--}}" } }, .{ .paired = .{ .begin = "{{!", .end = "}}" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".hcl", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "#" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".hh", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".hpp", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".hxx", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".hrl", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "%" }, .{ .line = "%%" } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".hs", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "--" }, .{ .paired = .{ .begin = "{-", .end = "-}" } }, .{ .paired = .{ .begin = "{-|", .end = "-}" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".idr", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "--" }, .{ .paired = .{ .begin = "{-", .end = "-}" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".htm", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<!--", .end = "-->" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".html", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<!--", .end = "-->" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".http", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".ini", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = ";" }, .{ .line = "#" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".j2", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "{#", .end = "#}" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".java", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".jenkinsfile", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".jinja", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "{#", .end = "#}" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".jl", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "#=", .end = "=#" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".js", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".json", FileTypeInfo{ .comments = &[_]Comment{}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".json5", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".jsonc", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".jsx", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".ksh", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".kt", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".kts", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".latex", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "%" }}, .indent = .off } },
    .{ ".lean", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "--" }, .{ .paired = .{ .begin = "/-", .end = "-/" } }, .{ .paired = .{ .begin = "/--", .end = "-/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".less", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".liquid", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "{% comment %}", .end = "{% endcomment %}" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".lisp", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".lua", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "--" }, .{ .paired = .{ .begin = "--[[", .end = "]]" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".mak", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
    .{ ".make", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
    .{ ".markdown", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<!--", .end = "-->" } }}, .indent = .off } },
    .{ ".md", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<!--", .end = "-->" } }}, .indent = .off } },
    .{ ".mjs", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".mk", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
    .{ ".ml", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "(*", .end = "*)" } }, .{ .paired = .{ .begin = "(**", .end = "*)" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".mli", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "(*", .end = "*)" } }, .{ .paired = .{ .begin = "(**", .end = "*)" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".mustache", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "{{!", .end = "}}" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".nginx", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".nim", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .line = "##" }, .{ .paired = .{ .begin = "#[", .end = "]#" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".nix", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".nqp", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".p6", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "#`(", .end = ")" } }, .{ .paired = .{ .begin = "#`[", .end = "]" } }, .{ .paired = .{ .begin = "#`{", .end = "}" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".php", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .line = "#" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".pl", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".pm", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".pm6", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "#`(", .end = ")" } }, .{ .paired = .{ .begin = "#`[", .end = "]" } }, .{ .paired = .{ .begin = "#`{", .end = "}" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".po", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .off } },
    .{ ".pot", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .off } },
    .{ ".properties", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .line = "!" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".proto", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".proto3", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".ps1", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "<#", .end = "#>" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".psm1", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "<#", .end = "#>" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".psql", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "--" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".purs", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "--" }, .{ .paired = .{ .begin = "{-", .end = "-}" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".py", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".r", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".rake", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".raku", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "#`(", .end = ")" } }, .{ .paired = .{ .begin = "#`[", .end = "]" } }, .{ .paired = .{ .begin = "#`{", .end = "}" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".rakumod", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "#`(", .end = ")" } }, .{ .paired = .{ .begin = "#`[", .end = "]" } }, .{ .paired = .{ .begin = "#`{", .end = "}" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".rakutest", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .paired = .{ .begin = "#`(", .end = ")" } }, .{ .paired = .{ .begin = "#`[", .end = "]" } }, .{ .paired = .{ .begin = "#`{", .end = "}" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".rb", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".red", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = ";" }, .{ .line = ";;" }, .{ .line = ";--" }, .{ .paired = .{ .begin = "comment {", .end = "}" } } }, .indent = .{ .default = .{ .width = 4, .char = '\t' } } } },
    .{ ".reds", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = ";" }, .{ .line = ";;" }, .{ .line = ";--" }, .{ .paired = .{ .begin = "comment {", .end = "}" } } }, .indent = .{ .default = .{ .width = 4, .char = '\t' } } } },
    .{ ".rkt", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = ";" }, .{ .paired = .{ .begin = "#|", .end = "|#" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".rs", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "///" }, .{ .line = "//!" }, .{ .paired = .{ .begin = "/**", .end = "*/" } }, .{ .paired = .{ .begin = "/*!", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".rst", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ".." }}, .indent = .off } },
    .{ ".s", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".sass", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".scala", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".scm", FileTypeInfo{ .comments = &[_]Comment{.{ .line = ";" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".scss", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".sed", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".service", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "#" }, .{ .line = ";" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".sh", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".smk", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".sql", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "--" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".st", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "\"", .end = "\"" } }}, .indent = .{ .default = .{ .width = 4, .char = '\t' } } } },
    .{ ".styl", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".sv", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".svelte", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "<!--", .end = "-->" } }, .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".svg", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<!--", .end = "-->" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".swift", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "///" }, .{ .paired = .{ .begin = "/**", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".tcsh", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".tex", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "%" }}, .indent = .off } },
    .{ ".tf", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "#" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".tfvars", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "#" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".thrift", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "#" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".toml", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".ts", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".tsx", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".twig", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "{#", .end = "#}" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".txt", text_file_type_info },
    .{ ".v", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".vb", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "'" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".vba", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "'" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".vbhtml", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "<!--", .end = "-->" } }, .{ .paired = .{ .begin = "@*", .end = "*@" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".vbs", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "'" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".vert", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".vhd", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "--" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".vhdl", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "--" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".vue", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "<!--", .end = "-->" } }, .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".wgsl", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "//" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".x", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "--" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".xaml", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<!--", .end = "-->" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".xhtml", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<!--", .end = "-->" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".xml", FileTypeInfo{ .comments = &[_]Comment{.{ .paired = .{ .begin = "<!--", .end = "-->" } }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".y", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "//" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".yy", FileTypeInfo{ .comments = &[_]Comment{ .{ .paired = .{ .begin = "/*", .end = "*/" } }, .{ .line = "//" } }, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".yaml", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".yml", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ ".yrl", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "%" }, .{ .line = "%%" } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".zig", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .line = "///" }, .{ .line = "//!" } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ ".zsh", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "AUTHORS", text_file_type_info },
    .{ "BSDmakefile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
    .{ "BUILD", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ "CHANGELOG", text_file_type_info },
    .{ "CHANGES", text_file_type_info },
    .{ "CONTRIBUTING", text_file_type_info },
    .{ "CONTRIBUTORS", text_file_type_info },
    .{ "COPYRIGHT", text_file_type_info },
    .{ "Capfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "Containerfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "Dockerfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "Doxyfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "GNUMakefile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
    .{ "GNUmakefile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
    .{ "Gemfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "Guardfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "HISTORY", text_file_type_info },
    .{ "Jenkinsfile", FileTypeInfo{ .comments = &[_]Comment{ .{ .line = "//" }, .{ .paired = .{ .begin = "/*", .end = "*/" } } }, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ "Justfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "LICENCE", text_file_type_info },
    .{ "Makefile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
    .{ "NOTICE", text_file_type_info },
    .{ "Podfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "Procfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "README", text_file_type_info },
    .{ "Rakefile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "SConscript", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ "SConstruct", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ "SECURITY", text_file_type_info },
    .{ "Snakefile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ "TODO", text_file_type_info },
    .{ "Tiltfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ "Vagrantfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "WORKSPACE", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 4, .char = ' ' } } } },
    .{ "justfile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 2, .char = ' ' } } } },
    .{ "makefile", FileTypeInfo{ .comments = &[_]Comment{.{ .line = "#" }}, .indent = .{ .default = .{ .width = 8, .char = '\t' } } } },
});

fn recursivelyUpdate(
    ctx: GlobalContext,
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
            try recursivelyUpdate(ctx, dir, entry.name, entry.kind);
        }
    } else if (kind == .file) {
        try updateFile(ctx, parent_dir, name);
    }
}

fn updateFile(
    ctx: GlobalContext,
    dir: std.fs.Dir,
    file_name: []const u8,
) !void {
    std.log.debug("Updating file: {s}", .{file_name});
    const ext = std.fs.path.extension(file_name);
    const file_type_info = file_type_info_map.get(ext) orelse
        file_type_info_map.get(file_name) orelse return;

    const allocator = ctx.arena.allocator();
    defer _ = ctx.arena.reset(.{ .retain_with_limit = 1024 * 1024 });
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
    var settings: FileSettings = .{
        .current_indent = .{
            .enabled = file_type_info.indent != .off,
            .start_width = 0,
        },
    };

    while (lines.next()) |line| : (line_number += 1) {
        if (mightMatchTag(line)) {
            switch (try updateChunk(
                allocator,
                ctx,
                file_name,
                &line_number,
                &updated_bytes,
                &lines,
                line,
                file_type_info,
                &settings,
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
        std.log.warn("File has conflicts: {s}\n", .{git_path});
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
    comment: Comment,
};

const Indent = struct {
    enabled: bool = true,

    // The exact whitespace slice from column 0 to the start of the copyv comment
    start_slice: []const u8 = "",

    // This is pre-multiplied with `width` (or even allows non-width aligned starting indents)
    start_width: ?usize = null,

    width: ?usize = null,
    char: ?u8 = null, // ' ' or '\t'
};

const FileSettings = struct {
    freeze: bool = false,
    current_indent: Indent = .{},
    base_indent: Indent = .{},
    new_indent: Indent = .{},
};

const line_whitespace = " \t";

fn matchesTag(
    line: []const u8,
    file_type_info: FileTypeInfo,
    file_indent: *Indent,
    file_bytes: []const u8,
    debug_indent: bool,
) ?Match {
    const line_trimmed = std.mem.trimStart(u8, line, line_whitespace);
    for (file_type_info.comments) |comment| {
        const comment_prefix = switch (comment) {
            .line => |prefix| prefix,
            .paired => |p| p.begin,
        };

        if (std.mem.startsWith(u8, line_trimmed, comment_prefix)) {
            const tag = line_trimmed[comment_prefix.len..];
            const tag_trimmed = std.mem.trimStart(u8, tag, line_whitespace);
            if (std.mem.startsWith(u8, tag_trimmed, copyv_tag)) {
                const comment_start = line.len - line_trimmed.len;
                const tag_whitespace = tag.len - tag_trimmed.len;
                const prefix_len = comment_start + comment_prefix.len + tag_whitespace + copyv_tag.len;
                const prefix = line[0..prefix_len];
                const start_slice = line[0..comment_start];
                var start_width: ?usize = null;

                if (file_indent.enabled) {
                    getIndent(file_indent, file_bytes, file_type_info, debug_indent);
                    const reason = getIndentStart(
                        &start_width,
                        start_slice,
                        file_indent.width.?,
                        file_indent.char.?,
                    );
                    if (debug_indent) {
                        std.log.info("indent start_width={d} ({s})", .{
                            start_width.?,
                            @tagName(reason),
                        });
                    }
                }

                return .{
                    .prefix = prefix,
                    .indent = .{
                        .enabled = file_indent.enabled,
                        .start_slice = start_slice,
                        .start_width = start_width,
                        .width = file_indent.width,
                        .char = file_indent.char,
                    },
                    .comment = comment,
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
    try updated_bytes.appendSlice(allocator, indent.start_slice);

    switch (file_type_info.comments[0]) {
        .line => |prefix| {
            try updated_bytes.appendSlice(allocator, prefix);
            try updated_bytes.appendSlice(allocator, " copyv: end");
        },
        .paired => |p| {
            try updated_bytes.appendSlice(allocator, p.begin);
            try updated_bytes.appendSlice(allocator, " copyv: end ");
            try updated_bytes.appendSlice(allocator, p.end);
        },
    }
}

const ChunkStatus = enum {
    updated,
    updated_with_conflicts,
    untouched,
    not_a_chunk,
};

const FetchError = error{
    HttpError,
};

fn skipBlockUntouched(
    allocator: std.mem.Allocator,
    action: Action,
    updated_bytes: *std.ArrayList(u8),
    lines: *std.mem.SplitIterator(u8, .scalar),
    current_line: []const u8,
    indent: Indent,
    file_type_info: FileTypeInfo,
    file_name: []const u8,
    line_number: *usize,
) !ChunkStatus {
    if (action == .track or action == .check_freeze) {
        const current_start = current_line.ptr - lines.buffer.ptr;
        const end_line = skipToEndLine(
            lines,
            indent,
            file_type_info,
            file_name,
            line_number,
        );
        const current_end = end_line.ptr - lines.buffer.ptr + end_line.len;
        try updated_bytes.appendSlice(
            allocator,
            lines.buffer[current_start..current_end],
        );
        try maybeAppendNewline(allocator, updated_bytes, lines);
    } else {
        try updated_bytes.appendSlice(allocator, current_line);
        try maybeAppendNewline(allocator, updated_bytes, lines);
    }
    return .untouched;
}

fn updateChunk(
    allocator: std.mem.Allocator,
    ctx: GlobalContext,
    file_name: []const u8,
    line_number: *usize,
    updated_bytes: *std.ArrayList(u8),
    lines: *std.mem.SplitIterator(u8, .scalar),
    current_line: []const u8,
    file_type_info: FileTypeInfo,
    file_settings: *FileSettings,
) !ChunkStatus {
    // Check if matches tag
    const maybe_match = matchesTag(
        current_line,
        file_type_info,
        &file_settings.current_indent,
        lines.buffer,
        ctx.debug_indent,
    );

    if (maybe_match == null) {
        return .not_a_chunk;
    }

    const match = maybe_match.?;
    const prefix = match.prefix;
    var indent: Indent = match.indent;
    var base_indent: Indent = file_settings.base_indent;
    var new_indent: Indent = file_settings.new_indent;

    // Get the files from remote

    var line_remainder = current_line[prefix.len..];
    switch (match.comment) {
        .line => {},
        .paired => |p| {
            if (std.mem.lastIndexOf(u8, line_remainder, p.end)) |idx| {
                line_remainder = line_remainder[0..idx];
            }
        },
    }
    const line_payload = std.mem.trim(u8, line_remainder, line_whitespace);
    var line_args = std.mem.splitScalar(u8, line_payload, ' ');

    var url_with_line_numbers: []const u8 = undefined;
    var has_command: bool = false;
    var has_url: bool = false;

    while (line_args.next()) |arg| {
        if (std.mem.eql(u8, arg, "end")) {
            std.debug.panic(
                "{s}[{d}]: Unexpected 'copyv: end' outside of a copyv chunk\n",
                .{ file_name, line_number.* },
            );
        } else if (std.mem.eql(u8, arg, "indent") or std.mem.eql(u8, arg, "our-indent")) {
            has_command = true;
            handleIndentCommands(
                &line_args,
                &file_settings.current_indent,
                true,
                lines.buffer,
                file_type_info,
                file_name,
                line_number.*,
                ctx.debug_indent,
            );
        } else if (std.mem.eql(u8, arg, "their-indent")) {
            has_command = true;
            handleIndentCommands(
                &line_args,
                &file_settings.new_indent,
                false,
                lines.buffer,
                file_type_info,
                file_name,
                line_number.*,
                ctx.debug_indent,
            );
            copyIndentAsDefault(
                &file_settings.base_indent,
                file_settings.new_indent,
            );
        } else if (std.mem.eql(u8, arg, "base-indent")) {
            has_command = true;
            handleIndentCommands(
                &line_args,
                &file_settings.base_indent,
                false,
                lines.buffer,
                file_type_info,
                file_name,
                line_number.*,
                ctx.debug_indent,
            );
            copyIndentAsDefault(
                &file_settings.new_indent,
                file_settings.base_indent,
            );
        } else if (std.mem.eql(u8, arg, "freeze") or std.mem.eql(u8, arg, "frozen")) {
            has_command = true;
            file_settings.freeze = true;
        } else if (std.mem.startsWith(u8, arg, "https://")) {
            if (has_command) {
                std.debug.panic(
                    "{s}[{d}]: Unexpected URL after command. Command must either follow URL (applies only to that block), or be on a separate line (applies to all following blocks in the file)\n",
                    .{ file_name, line_number.* },
                );
            }

            has_url = true;
            url_with_line_numbers = arg;
            break;
        } else if (arg.len > 0) {
            std.debug.panic(
                "{s}[{d}]: Expected a valid command or a URL beginning with https:// after 'copyv:', got: {s}",
                .{ file_name, line_number.*, arg },
            );
        }
    }

    if (!has_command and !has_url) {
        std.debug.panic(
            "{s}[{d}]: Expected a command or a URL beginning with https:// after 'copyv:'",
            .{ file_name, line_number.* },
        );
    }

    if (has_command) {
        try updated_bytes.appendSlice(allocator, current_line);
        try maybeAppendNewline(allocator, updated_bytes, lines);
        return .untouched;
    }

    var chunk_action: Action = .get;

    while (line_args.next()) |command| {
        if (std.mem.eql(u8, command, "begin")) {
            if (chunk_action != .check_freeze) {
                chunk_action = .track;
            }
        } else if (std.mem.eql(u8, command, "freeze")) {
            chunk_action = .check_freeze;
        } else if (std.mem.startsWith(u8, command, "gf")) { // get freeze
            chunk_action = .get_freeze;
        } else if (std.mem.startsWith(u8, command, "g")) { // get
            if (line_args.peek()) |peek| {
                if (std.mem.startsWith(u8, peek, "f")) { // freeze
                    chunk_action = .get_freeze;

                    // Consume peeked arg
                    _ = line_args.next();
                } else {
                    chunk_action = .get;
                }
            } else {
                chunk_action = .get;
            }
        } else if (std.mem.eql(u8, command, "indent") or std.mem.eql(u8, command, "our-indent")) {
            handleIndentCommands(
                &line_args,
                &indent,
                true,
                lines.buffer,
                file_type_info,
                file_name,
                line_number.*,
                ctx.debug_indent,
            );
        } else if (std.mem.eql(u8, command, "their-indent")) {
            handleIndentCommands(
                &line_args,
                &new_indent,
                false,
                lines.buffer,
                file_type_info,
                file_name,
                line_number.*,
                ctx.debug_indent,
            );
            copyIndentAsDefault(
                &base_indent,
                new_indent,
            );
        } else if (std.mem.eql(u8, command, "base-indent")) {
            handleIndentCommands(
                &line_args,
                &base_indent,
                false,
                lines.buffer,
                file_type_info,
                file_name,
                line_number.*,
                ctx.debug_indent,
            );
            copyIndentAsDefault(
                &new_indent,
                base_indent,
            );
        } else if (command.len > 0) {
            std.debug.panic("{s}[{d}]: Unknown command: {s}\n", .{
                file_name,
                line_number.*,
                command,
            });
        }
    }

    const action: Action = if (file_settings.freeze)
        .check_freeze
    else
        chunk_action;

    const after_protocol = url_with_line_numbers["https://".len..];
    const host_end = std.mem.indexOfScalar(u8, after_protocol, '/') orelse {
        std.debug.panic("{s}[{d}]: URL must contain path after host\n", .{ file_name, line_number.* });
    };
    const host = after_protocol[0..host_end];
    const url_path = after_protocol[host_end + 1 ..]; // strip leading '/'

    const platform = Platform.parse(host) catch {
        std.debug.panic("{s}[{d}]: Unsupported host: {s}\n", .{
            file_name,
            line_number.*,
            host,
        });
    };

    const marker = switch (platform) {
        .github => "/blob/",
        .gitlab => "/-/blob/",
        .codeberg => "/src/",
    };
    const marker_index = std.mem.indexOf(u8, url_path, marker) orelse {
        std.debug.panic("{s}[{d}]: URL must contain {s}\n", .{ file_name, line_number.*, marker });
    };
    const repo = url_path[0..marker_index];
    const after_marker = url_path[marker_index + marker.len ..];
    var parts = std.mem.splitScalar(u8, after_marker, '/');
    if (platform == .codeberg) _ = parts.next().?; // skip mode (e.g. "commit")
    const ref = parts.next().?;
    const path_with_query_and_fragment = parts.rest();

    if (!ctx.platform_filter.isEnabled(platform) or action == .check_freeze) {
        if (ctx.platform_filter.isEnabled(platform) and ref.len != 40) {
            std.debug.panic(
                "{s}[{d}]: 'freeze' line must point to a commit SHA\n",
                .{ file_name, line_number.* },
            );
        }

        return skipBlockUntouched(
            allocator,
            action,
            updated_bytes,
            lines,
            current_line,
            indent,
            file_type_info,
            file_name,
            line_number,
        );
    }

    const fragment_index = std.mem.indexOfScalar(u8, path_with_query_and_fragment, '#');
    const whole_file = fragment_index == null;
    const path_with_query = path_with_query_and_fragment[0..(fragment_index orelse path_with_query_and_fragment.len)];
    const path_end = std.mem.indexOfScalar(u8, path_with_query, '?') orelse path_with_query.len;
    const path = path_with_query[0..path_end];

    var base_start: usize = undefined;
    var base_end: usize = undefined;
    if (!whole_file) {
        const line_numbers_str = path_with_query_and_fragment[fragment_index.? + 1 ..];
        var line_numbers = std.mem.splitScalar(u8, line_numbers_str, '-');
        const base_start_str = line_numbers.first()["L".len..];
        base_start = try std.fmt.parseUnsigned(usize, base_start_str, 10);
        if (line_numbers.next()) |end_str| {
            const base_end_str = switch (platform) {
                .github, .codeberg => end_str["L".len..],
                .gitlab => end_str,
            };
            base_end = try std.fmt.parseUnsigned(usize, base_end_str, 10);
        } else {
            base_end = base_start;
        }
    }

    const base_sha = if (ref.len == 40)
        ref
    else
        fetchLatestCommitSha(allocator, ctx.sha_cache, platform, repo, ref) catch |err| switch (err) {
            FetchError.HttpError => return skipBlockUntouched(
                allocator,
                action,
                updated_bytes,
                lines,
                current_line,
                indent,
                file_type_info,
                file_name,
                line_number,
            ),
            else => return err,
        };

    const base_file = fetchFile(
        allocator,
        ctx.cache_dir,
        platform,
        repo,
        base_sha,
        path,
    ) catch |err| switch (err) {
        FetchError.HttpError => return skipBlockUntouched(
            allocator,
            action,
            updated_bytes,
            lines,
            current_line,
            indent,
            file_type_info,
            file_name,
            line_number,
        ),
        else => return err,
    };
    const base_bytes = if (whole_file)
        removeFinalNewline(base_file.data)
    else
        try getLines(base_file.data, base_start, base_end);

    var base_indented = try std.ArrayList(u8).initCapacity(allocator, base_bytes.len);
    try matchIndent(
        allocator,
        &base_indented,
        base_bytes,
        indent,
        base_indent,
        file_type_info,
        ctx.debug_indent,
    );

    var current_chunk: []const u8 = undefined;
    if (action == .track) {
        const current_start = current_line.ptr - lines.buffer.ptr + current_line.len + 1;
        const end_line = skipToEndLine(
            lines,
            indent,
            file_type_info,
            file_name,
            line_number,
        );
        const current_end = end_line.ptr - lines.buffer.ptr - 1;
        current_chunk = lines.buffer[current_start..current_end];
    }

    const new_sha = if (action == .get_freeze)
        base_sha
    else
        fetchLatestCommitSha(allocator, ctx.sha_cache, platform, repo, "HEAD") catch |err| switch (err) {
            FetchError.HttpError => return skipBlockUntouched(
                allocator,
                action,
                updated_bytes,
                lines,
                current_line,
                indent,
                file_type_info,
                file_name,
                line_number,
            ),
            else => return err,
        };

    var new_start: usize = undefined;
    var new_end: usize = undefined;
    var updated_chunk: []const u8 = undefined;
    var has_conflicts = false;

    if (std.mem.eql(u8, new_sha, base_sha)) {
        new_start = base_start;
        new_end = base_end;
        switch (action) {
            .get, .get_freeze => {
                updated_chunk = base_indented.items;
            },
            .track => {
                updated_chunk = current_chunk;
            },
            else => unreachable,
        }
    } else {
        std.debug.assert(action == .track or (action == .get and ref.len == 40));
        const new_file = fetchFile(
            allocator,
            ctx.cache_dir,
            platform,
            repo,
            new_sha,
            path,
        ) catch |err| switch (err) {
            FetchError.HttpError => return skipBlockUntouched(
                allocator,
                action,
                updated_bytes,
                lines,
                current_line,
                indent,
                file_type_info,
                file_name,
                line_number,
            ),
            else => return err,
        };

        const new_bytes = if (whole_file)
            removeFinalNewline(new_file.data)
        else new_bytes: {
            new_start = 0;
            new_end = 0;

            // Diff the files

            var base_file_path_buffer: [1024]u8 = undefined;
            var new_file_path_buffer: [1024]u8 = undefined;
            const base_file_path = try ctx.cache_dir.realpath(base_file.name, &base_file_path_buffer);
            const new_file_path = try ctx.cache_dir.realpath(new_file.name, &new_file_path_buffer);

            const diff_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "diff", "--no-index", base_file_path, new_file_path },
                .max_output_bytes = max_file_bytes,
            });

            // Check if diff is in the chunk

            var diff_lines = std.mem.splitScalar(u8, diff_result.stdout, '\n');
            var base_line: usize = 0;
            var new_line: usize = 0;
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
                } else if (base_line == base_end + 1) {
                    // In case there's a series of '-' lines followed by a series of
                    // '+' lines right at the end of the chunk, we want to capture
                    // that, so we need this extra check.

                    new_end = new_line - 1;
                }
            }

            if (has_diff_in_chunk) {
                // We've at least set the start because the diff affected the chunk
                std.debug.assert(new_start != 0);

                if (new_end == 0) {
                    // The only diffs were before the end of this chunk
                    std.debug.assert(base_line < base_end);
                    const delta = @as(isize, @intCast(new_line)) - @as(isize, @intCast(base_line));
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

            break :new_bytes try getLines(new_file.data, new_start, new_end);
        };
        var new_indented = try std.ArrayList(u8).initCapacity(allocator, new_bytes.len);
        try matchIndent(
            allocator,
            &new_indented,
            new_bytes,
            indent,
            new_indent,
            file_type_info,
            ctx.debug_indent,
        );

        try ctx.cache_dir.writeFile(.{ .sub_path = "base", .data = base_indented.items });
        try ctx.cache_dir.writeFile(.{ .sub_path = "new", .data = new_indented.items });
        var base_chunk_path_buffer: [1024]u8 = undefined;
        var new_chunk_path_buffer: [1024]u8 = undefined;
        const base_chunk_path = try ctx.cache_dir.realpath("base", &base_chunk_path_buffer);
        const new_chunk_path = try ctx.cache_dir.realpath("new", &new_chunk_path_buffer);

        // Determine updated chunk bytes

        if (action == .get or std.mem.eql(u8, current_chunk, base_indented.items)) {
            updated_chunk = new_indented.items;
        } else {
            std.log.info("Merging file: {s}", .{file_name});
            std.debug.assert(action == .track);
            try ctx.cache_dir.writeFile(.{ .sub_path = "current", .data = current_chunk });
            var current_chunk_path_buffer: [1024]u8 = undefined;
            const current_chunk_path = try ctx.cache_dir.realpath(
                "current",
                &current_chunk_path_buffer,
            );

            const config_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = &.{ "git", "config", "--get", "merge.conflictstyle" },
            });
            const conflict_style = std.mem.trim(u8, config_result.stdout, line_whitespace);
            var merge_args = try std.ArrayList([]const u8).initCapacity(allocator, 12);
            merge_args.appendSliceAssumeCapacity(
                &[_][]const u8{
                    "git",
                    "merge-file",
                    "-p",
                    "-L",
                    "ours",
                    "-L",
                    "base",
                    "-L",
                    "theirs",
                },
            );

            if (std.mem.eql(u8, conflict_style, "diff3")) {
                merge_args.appendAssumeCapacity("--diff3");
            } else if (std.mem.eql(u8, conflict_style, "zdiff3")) {
                merge_args.appendAssumeCapacity("--zdiff3");
            }

            merge_args.appendSliceAssumeCapacity(&[_][]const u8{
                current_chunk_path,
                base_chunk_path,
                new_chunk_path,
            });

            const merge_result = try std.process.Child.run(.{
                .allocator = allocator,
                .argv = merge_args.items,
                .max_output_bytes = max_file_bytes,
            });
            updated_chunk = merge_result.stdout;

            switch (merge_result.term) {
                .Exited => |code| {
                    if (code >= 127) {
                        std.debug.panic("{s}[{d}]: Unexpected merge result error code: {d}\n", .{
                            file_name,
                            line_number.*,
                            code,
                        });
                    } else if (code != 0) {
                        has_conflicts = true;
                    }
                },
                else => {
                    std.debug.panic("{s}[{d}]: Unexpected merge result term\n", .{
                        file_name,
                        line_number.*,
                    });
                },
            }
        }
    }

    // Write back bytes

    const command = if (action == .get_freeze) "freeze" else "begin";
    const enabled_differs = indent.enabled != file_settings.current_indent.enabled;
    const indent_differs = enabled_differs or (indent.enabled and
        (indent.width.? != file_settings.current_indent.width.? or
        indent.char.? != file_settings.current_indent.char.?));
    // We don't care if base indent differs, since we've already merged in the
    // new changes by now.
    const new_char_differs = new_indent.char != file_settings.base_indent.char;
    const new_width_differs = new_indent.width != file_settings.base_indent.width;
    const new_indent_differs = new_char_differs or new_width_differs;
    var commands: []const u8 = undefined;
    if (indent_differs or new_indent_differs) {
        var array = try std.ArrayList([]const u8).initCapacity(allocator, 10);
        if (indent_differs) {
            if (new_indent_differs) {
                array.appendAssumeCapacity("our-indent");
            } else {
                array.appendAssumeCapacity("indent");
            }
        }
        if (enabled_differs) {
            array.appendAssumeCapacity(if (indent.enabled) "on" else "off");
        }
        if (indent.enabled and indent.char.? != file_settings.current_indent.char.?) {
            array.appendAssumeCapacity(if (indent.char.? == ' ')
                "spaces"
            else
                "tabs");
        }
        if (indent.enabled and indent.width.? != file_settings.current_indent.width.?) {
            array.appendAssumeCapacity(try std.fmt.allocPrint(
                allocator,
                "{d}",
                .{indent.width.?},
            ));
        }

        if (new_indent_differs) {
            // The `new_indent` is now the new `base_indent`
            array.appendAssumeCapacity("base-indent");

            if (new_char_differs) {
                array.appendAssumeCapacity(if (new_indent.char.? == ' ')
                    "spaces"
                else
                    "tabs");
            }

            if (new_width_differs) {
                array.appendAssumeCapacity(try std.fmt.allocPrint(
                    allocator,
                    "{d}",
                    .{new_indent.width.?},
                ));
            }
        }

        array.appendAssumeCapacity(command);
        commands = try std.mem.join(allocator, " ", array.items);
    } else {
        commands = command;
    }
    const line_fragment = if (whole_file)
        ""
    else switch (platform) {
        .github, .codeberg => try std.fmt.allocPrint(allocator, "#L{d}-L{d}", .{ new_start, new_end }),
        .gitlab => try std.fmt.allocPrint(allocator, "#L{d}-{d}", .{ new_start, new_end }),
    };
    const updated_url = switch (platform) {
        .github, .codeberg => try std.fmt.allocPrint(
            allocator,
            "{s} https://{s}/{s}/{s}/{s}/{s}{s} {s}",
            .{
                prefix,
                host,
                repo,
                if (platform == .github) "blob" else "src/commit",
                new_sha,
                path_with_query,
                line_fragment,
                commands,
            },
        ),
        .gitlab => try std.fmt.allocPrint(
            allocator,
            "{s} https://{s}/{s}/-/blob/{s}/{s}{s} {s}",
            .{
                prefix,
                host,
                repo,
                new_sha,
                path_with_query,
                line_fragment,
                commands,
            },
        ),
    };
    try updated_bytes.appendSlice(allocator, updated_url);
    switch (match.comment) {
        .line => {},
        .paired => |p| {
            try updated_bytes.append(allocator, ' ');
            try updated_bytes.appendSlice(allocator, p.end);
        },
    }
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

fn handleIndentCommands(
    args: *std.mem.SplitIterator(u8, .scalar),
    indent: *Indent,
    allow_enable_toggling: bool,
    file_bytes: []const u8,
    file_type_info: FileTypeInfo,
    file_name: []const u8,
    line_number: usize,
    debug_indent: bool,
) void {
    if (args.peek() == null) {
        std.debug.panic(
            "{s}[{d}]: Expected argument (e.g. 'off', 'tabs', 'spaces', '4') after 'indent' command\n",
            .{ file_name, line_number },
        );
    }

    while (true) {
        if (args.peek()) |peek| {
            if (std.mem.eql(u8, peek, "off")) {
                if (!allow_enable_toggling) {
                    std.debug.panic(
                        "{s}[{d}]: Argument 'off' not allowed for 'base-indent' or 'their-indent': use 'indent'/'our-indent' instead\n",
                        .{ file_name, line_number },
                    );
                }
                indent.enabled = false;
            } else if (std.mem.eql(u8, peek, "on")) {
                if (!allow_enable_toggling) {
                    std.debug.panic(
                        "{s}[{d}]: Argument 'on' not allowed for 'base-indent' or 'their-indent': use 'indent'/'our-indent' instead\n",
                        .{ file_name, line_number },
                    );
                }
                if (!indent.enabled) {
                    indent.enabled = true;
                    getIndent(indent, file_bytes, file_type_info, debug_indent);
                }
            } else if (std.mem.eql(u8, peek, "tab") or std.mem.eql(u8, peek, "tabs")) {
                indent.char = '\t';
            } else if (std.mem.eql(u8, peek, "space") or std.mem.eql(u8, peek, "spaces")) {
                indent.char = ' ';
            } else {
                // Unknown commands will be handled in caller
                indent.width = std.fmt.parseUnsigned(usize, peek, 10) catch break;
            }

            // Consume peeked arg
            _ = args.next();
        } else {
            break;
        }
    }
}

fn copyIndentAsDefault(
    dest: *Indent,
    source: Indent,
) void {
    if (dest.char == null) {
        dest.char = source.char;
    }
    if (dest.width == null) {
        dest.width = source.width;
    }
}

const GitRange = struct {
    start: usize,
    len: usize,
};

fn parseRange(range_str: []const u8) !GitRange {
    var parts = std.mem.splitScalar(u8, range_str, ',');
    const start_str = parts.next().?;
    const start = try std.fmt.parseUnsigned(usize, start_str[1..], 10);
    const len_str = parts.next().?;
    const len = try std.fmt.parseUnsigned(usize, len_str, 10);
    return .{ .start = start, .len = len };
}

fn fetchLatestCommitSha(
    allocator: std.mem.Allocator,
    sha_cache: *ShaCache,
    platform: Platform,
    repo: []const u8,
    ref: []const u8,
) ![]const u8 {
    const cache_key: ShaCacheKey = .{ .platform = platform, .repo = repo, .ref = ref };

    const gop = try sha_cache.getOrPut(cache_key);
    if (gop.found_existing) {
        return gop.value_ptr.*;
    }

    const api_url = switch (platform) {
        .github => try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/commits/{s}", .{ repo, ref }),
        .gitlab => blk: {
            const encoded_repo = try std.mem.replaceOwned(u8, allocator, repo, "/", "%2F");
            break :blk try std.fmt.allocPrint(allocator, "https://gitlab.com/api/v4/projects/{s}/repository/commits/{s}", .{ encoded_repo, ref });
        },
        .codeberg => try std.fmt.allocPrint(allocator, "https://codeberg.org/api/v1/repos/{s}/git/commits/{s}", .{ repo, ref }),
    };

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    var client = std.http.Client{ .allocator = allocator };

    var authorization: std.http.Client.Request.Headers.Value = undefined;

    switch (platform) {
        .github => {
            if (std.process.hasEnvVarConstant("GITHUB_TOKEN")) {
                const token = try std.process.getEnvVarOwned(allocator, "GITHUB_TOKEN");
                const auth_value = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
                authorization = .{ .override = auth_value };
            } else {
                authorization = .default;
            }
        },
        .gitlab, .codeberg => {
            authorization = .default;
        },
    }

    const result = try client.fetch(.{
        .location = .{ .url = api_url },
        .response_writer = &aw.writer,
        .headers = .{
            .authorization = authorization,
        },
    });

    const platform_name = switch (platform) {
        .github => "GitHub",
        .gitlab => "GitLab",
        .codeberg => "Codeberg",
    };

    const status_code = @intFromEnum(result.status);
    if (status_code >= 400) {
        const json_bytes = aw.toOwnedSlice() catch "";
        defer if (json_bytes.len > 0) allocator.free(json_bytes);
        std.log.err("{s} API error fetching commit SHA for {s}/{s}: HTTP {d} ({s}){s}{s}", .{
            platform_name,
            repo,
            ref,
            status_code,
            @tagName(result.status),
            if (json_bytes.len > 0) ": " else "",
            json_bytes,
        });
        return FetchError.HttpError;
    }

    const json_bytes = try aw.toOwnedSlice();
    defer allocator.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const sha_field_name = switch (platform) {
        .github, .codeberg => "sha",
        .gitlab => "id",
    };

    const sha = parsed.value.object.get(sha_field_name) orelse {
        std.log.err("{s} API error: missing '{s}' field in response for {s}/{s}: {s}", .{
            platform_name,
            sha_field_name,
            repo,
            ref,
            json_bytes,
        });
        return FetchError.HttpError;
    };

    const cache_allocator = sha_cache.allocator;
    gop.key_ptr.* = .{
        .platform = platform,
        .repo = try cache_allocator.dupe(u8, repo),
        .ref = try cache_allocator.dupe(u8, ref),
    };
    const sha_owned = try cache_allocator.dupe(u8, sha.string);
    gop.value_ptr.* = sha_owned;
    return sha_owned;
}

const max_file_bytes = 100_000_000;

const File = struct {
    name: []const u8,
    data: []const u8,
};

fn fetchFile(
    allocator: std.mem.Allocator,
    cache_dir: std.fs.Dir,
    platform: Platform,
    repo: []const u8,
    sha: []const u8,
    path: []const u8,
) !File {
    const name = try std.fmt.allocPrint(allocator, "files/{s}/{s}/{s}/{s}", .{ repo, path, sha[0..1], sha[1..] });
    if (cache_dir.readFileAlloc(allocator, name, max_file_bytes) catch null) |data| {
        return .{ .name = name, .data = data };
    }

    const url = switch (platform) {
        .github => try std.fmt.allocPrint(
            allocator,
            "https://raw.githubusercontent.com/{s}/{s}/{s}",
            .{ repo, sha, path },
        ),
        .gitlab => try std.fmt.allocPrint(
            allocator,
            "https://gitlab.com/{s}/-/raw/{s}/{s}",
            .{ repo, sha, path },
        ),
        .codeberg => try std.fmt.allocPrint(
            allocator,
            "https://codeberg.org/{s}/raw/commit/{s}/{s}",
            .{ repo, sha, path },
        ),
    };
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    var client = std.http.Client{ .allocator = allocator };
    const result = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });

    const status_code = @intFromEnum(result.status);
    if (status_code >= 400) {
        std.log.err("Failed to fetch file from {s}: HTTP {d} ({s})", .{
            url,
            status_code,
            @tagName(result.status),
        });
        return FetchError.HttpError;
    }

    const data = try aw.toOwnedSlice();
    if (std.fs.path.dirnamePosix(name)) |dir| {
        try cache_dir.makePath(dir);
    }
    try cache_dir.writeFile(.{ .sub_path = name, .data = data });
    return .{ .name = name, .data = data };
}

fn removeFinalNewline(bytes: []const u8) []const u8 {
    if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') {
        return bytes[0 .. bytes.len - 1];
    }
    return bytes;
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
    line_number: *usize,
) []const u8 {
    var file_indent = indent;
    var nesting: usize = 0;
    line_number.* += 1;

    return while (lines.next()) |line| : (line_number.* += 1) {
        if (!mightMatchTag(line)) continue;

        const match = matchesTag(line, file_type_info, &file_indent, "", false);
        if (match == null or !std.mem.eql(u8, match.?.indent.start_slice, indent.start_slice)) continue;

        const line_payload = std.mem.trim(u8, line[match.?.prefix.len..], line_whitespace);
        var line_args = std.mem.splitScalar(u8, line_payload, ' ');
        const first_arg = line_args.first();

        if (std.mem.startsWith(u8, first_arg, "end")) {
            if (nesting == 0) {
                break line;
            }

            nesting -= 1;
        } else if (std.mem.startsWith(u8, first_arg, "fr") or // "freeze"
            std.mem.startsWith(u8, first_arg, "tr") or // "track"
            std.mem.startsWith(u8, first_arg, "be") // "begin"
        ) {
            // TODO: delete this branch
            nesting += 1;
        } else if (line_args.next()) |command| {
            if (std.mem.eql(u8, command, "begin") or
                std.mem.eql(u8, command, "freeze"))
            {
                nesting += 1;
            }
        }
    } else {
        std.debug.panic(
            "{s}[{d}]: Expected copyv: end, but instead reached end of file\n",
            .{
                file_name,
                line_number.*,
            },
        );
    };
}

const shift_count_threshold = 6;
const indent_char_count_threshold = 10;
const indent_char_count_min = 4;
const max_indent_width = 16;

const StartWidthReason = enum { spaces, mixed, no_content };

fn getIndentStart(
    start_width: *?usize,
    whitespace: []const u8,
    file_type_common_indent: usize,
    indent_char: u8,
) StartWidthReason {
    if (indent_char == ' ') {
        start_width.* = whitespace.len;
        return .spaces;
    } else {
        const tab_count = std.mem.count(u8, whitespace, "\t");
        const space_count = std.mem.count(u8, whitespace, " ");

        // Note: this does not consider spaces that have no impact on
        // the indentation because they are followed by tabs, but for
        // well-formed whitespace, that shouldn't be the case.
        start_width.* = tab_count * file_type_common_indent + space_count;
        return .mixed;
    }
}

fn getIndent(indent: *Indent, bytes: []const u8, file_type_info: FileTypeInfo, debug: bool) void {
    const file_type_indent: FileTypeIndentDefault = switch (file_type_info.indent) {
        .off => .{ .width = 2, .char = ' ' },
        .default => |d| d,
    };

    if (indent.char == null) {
        const CharReason = enum { threshold, majority, file_type_default };
        var reason: CharReason = undefined;

        var space_count: usize = 0;
        var tab_count: usize = 0;

        var lines = std.mem.splitScalar(u8, bytes, '\n');
        indent.char = while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, " ")) {
                space_count += 1;
                if (space_count >= indent_char_count_threshold) {
                    reason = .threshold;
                    break ' ';
                }
            } else if (std.mem.startsWith(u8, line, "\t")) {
                tab_count += 1;
                if (tab_count >= indent_char_count_threshold) {
                    reason = .threshold;
                    break '\t';
                }
            }
        } else blk: {
            const seen = tab_count + space_count;
            if (seen >= indent_char_count_min) {
                reason = .majority;
                if (tab_count > space_count) break :blk '\t';
                if (space_count > tab_count) break :blk ' ';
            }
            reason = .file_type_default;
            break :blk file_type_indent.char;
        };

        if (debug) {
            const char_str: []const u8 = if (indent.char.? == ' ') "space" else "tab";
            std.log.info("indent char={s} ({s}, spaces={d}, tabs={d})", .{
                char_str,
                @tagName(reason),
                space_count,
                tab_count,
            });
        }
    }

    if (indent.start_width == null) {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const reason: StartWidthReason = while (lines.next()) |line| {
            const first_non_whitespace = std.mem.indexOfNone(u8, line, line_whitespace);
            if (first_non_whitespace) |index| {
                break getIndentStart(&indent.start_width, line[0..index], file_type_indent.width, indent.char.?);
            }
        } else blk: {
            indent.start_width = 0;
            break :blk .no_content;
        };

        if (debug) {
            std.log.info("indent start_width={d} ({s})", .{
                indent.start_width.?,
                @tagName(reason),
            });
        }
    }

    if (indent.width == null) {
        const WidthReason = enum { tab_file_type_default, threshold, max_count };
        var reason: WidthReason = undefined;
        var shift_counts: [max_indent_width]usize = @splat(0);

        if (indent.char.? == '\t') {
            indent.width = file_type_indent.width;
            reason = .tab_file_type_default;
        } else {
            // bias shift counts towards expected indents as a prior
            shift_counts[2] = 1;
            shift_counts[4] = 1;
            shift_counts[file_type_indent.width] += 1;

            var last_indent: usize = 0;
            var last_line_content: []const u8 = "a";
            var lines = std.mem.splitScalar(u8, bytes, '\n');
            indent.width = while (lines.next()) |line| {
                const first_non_whitespace = std.mem.indexOfNone(u8, line, line_whitespace);
                if (first_non_whitespace) |index| {
                    if (index != last_indent) {
                        const shift = @as(isize, @intCast(index)) -
                            @as(isize, @intCast(last_indent));

                        // * Ignore de-indent shifts, since some languages can
                        //   de-indent multiple blocks at once (e.g. Python, or Lisps).
                        // * Ignore shifts after lines starting with '*' and '-' that
                        //   might be part of a block comment bulleted list.
                        // * Ignore shifts after lines starting with `/*` since
                        //   that is also probably part of a block comment.
                        if (shift > 0 and
                            last_line_content[0] != '*' and
                            last_line_content[0] != '-' and
                            !std.mem.startsWith(u8, last_line_content, "/*"))
                        {
                            if (shift < shift_counts.len) {
                                const abs_shift = @abs(shift);
                                shift_counts[abs_shift] += 1;
                                if (shift_counts[abs_shift] >= shift_count_threshold) {
                                    reason = .threshold;
                                    break abs_shift;
                                }
                            }
                        }

                        last_indent = index;
                    }

                    last_line_content = line[index..];
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
                reason = .max_count;
                break :blk shift;
            };
        }

        if (debug) {
            std.log.info("indent width={d} ({s}, shift_counts={any})", .{
                indent.width.?,
                @tagName(reason),
                shift_counts,
            });
        }
    }
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
    current_override: Indent,
    file_type_info: FileTypeInfo,
    debug_indent: bool,
) !void {
    if (!desired.enabled) {
        try updated_bytes.appendSlice(allocator, bytes);
        return;
    }

    var current = current_override;
    getIndent(&current, bytes, file_type_info, debug_indent);

    const current_width = current.width.?;
    const current_start = current.start_width.?;
    const current_char = current.char.?;
    const desired_width = desired.width.?;
    const desired_start = desired.start_width.?;
    const desired_char = desired.char.?;

    // Fast path for equal indents
    if (current_width == desired_width and
        current_start == desired_start and
        current_char == desired_char)
    {
        try updated_bytes.appendSlice(allocator, bytes);
        return;
    }

    // Simpler path for consistent indents (same char and for spaces same width,
    // or for tabs, starts that are aligned with the widths)
    if (current_char == desired_char and
        ((desired_char == ' ' and current_width == desired_width) or (desired_char == '\t' and
            current_start % current_width == 0 and
            desired_start % desired_width == 0)))
    {
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        var desired_indent: usize = undefined;
        var current_indent: usize = undefined;
        if (desired_char == '\t') {
            desired_indent = desired_start / desired_width;
            current_indent = current_start / current_width;
        } else {
            desired_indent = desired_start;
            current_indent = current_start;
        }
        if (desired_indent > current_indent) {
            const add = desired_indent - current_indent;
            const add_bytes = try getWhitespace(allocator, desired_char, add);
            while (lines.next()) |line| {
                const line_start = std.mem.indexOfNone(u8, line, line_whitespace) orelse line.len;
                if (line_start > 0 or (line.len > 0 and current_start == 0)) {
                    try updated_bytes.appendSlice(allocator, add_bytes);
                }
                // This will leave whitespace in whitespace-only lines
                try updated_bytes.appendSlice(allocator, line);
                if (lines.peek() != null) {
                    try updated_bytes.append(allocator, '\n');
                }
            }
        } else {
            const remove = current_indent - desired_indent;
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

    if (desired_char == ' ') {
        desired_spaces = desired_start;
        desired_whitespace = try getWhitespace(
            allocator,
            ' ',
            desired_spaces,
        );
    } else {
        desired_tabs = desired_start / desired_width;
        desired_spaces = desired_start - desired_start % desired_width;
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
        const line_width = tab_count * current_width + space_count;
        var whitespace: []const u8 = undefined;

        if (line_width > current_start) {
            const over_start = line_width - current_start;
            const over_indents = over_start / current_width;
            const over_spaces = over_start - over_indents * current_width;
            whitespace = if (desired_char == ' ')
                try getWhitespace(
                    allocator,
                    ' ',
                    desired_spaces + over_indents * desired_width + over_spaces,
                )
            else
                try getMixedWhitespace(allocator, desired_tabs + over_indents, desired_spaces + over_spaces);
        } else {
            whitespace = desired_whitespace;
        }

        if (line_start > 0 or (line.len > 0 and current_start == 0)) {
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

    const cwd = std.fs.cwd();

    // Find repo root by walking up parent directories looking for .git
    var repo_root = cwd;
    var search_dir = cwd;
    while (true) {
        if (search_dir.statFile(".git")) |_| {
            repo_root = search_dir;
            break;
        } else |_| {}
        search_dir = search_dir.openDir("..", .{}) catch break;
    }

    const cache_dir_name = ".copyv-cache";
    repo_root.makeDir(cache_dir_name) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const cache_dir = try repo_root.openDir(cache_dir_name, .{});

    const allocator = arena.allocator();

    var sha_cache = ShaCache.init(std.heap.page_allocator);
    defer sha_cache.deinit();

    var arg_it = try std.process.argsWithAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.next();

    var blacklist = PlatformFilter.blacklist_default;
    var whitelist = PlatformFilter.whitelist_default;
    var current_filter: *PlatformFilter = &blacklist;
    var debug_indent = false;
    var name: []const u8 = ".";
    var kind: std.fs.File.Kind = .directory;

    while (arg_it.next()) |arg| {
        const is_platform = std.mem.startsWith(u8, arg, "--platform");
        const is_no_platform = !is_platform and std.mem.startsWith(u8, arg, "--no-platform");

        if (is_platform or is_no_platform) {
            const enable = is_platform;
            if (enable) current_filter = &whitelist;

            const host = if (std.mem.indexOf(u8, arg, "=")) |eq_idx|
                arg[eq_idx + 1 ..]
            else
                arg_it.next() orelse
                    std.debug.panic("{s} requires a value\n", .{arg});

            const platform = Platform.parse(host) catch {
                std.debug.panic("Unknown platform: {s}\n", .{host});
            };
            current_filter.setPlatform(platform, enable);
        } else if (std.mem.eql(u8, arg, "--debug-indent")) {
            debug_indent = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            std.debug.panic("Unknown option: {s}\n", .{arg});
        } else {
            name = arg;
            const stat = try std.fs.cwd().statFile(arg);
            kind = stat.kind;
            break;
        }
    }

    const ctx = GlobalContext{
        .arena = &arena,
        .cache_dir = cache_dir,
        .sha_cache = &sha_cache,
        .platform_filter = current_filter.*,
        .debug_indent = debug_indent,
    };

    try recursivelyUpdate(ctx, std.fs.cwd(), name, kind);

    while (arg_it.next()) |arg| {
        const stat = std.fs.cwd().statFile(arg) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.mem.startsWith(u8, arg, "-")) {
                    std.debug.panic("Options must be specified before the first file (or this file isn't found): {s}\n", .{arg});
                }
                return err;
            },
            else => |e| return e,
        };

        try recursivelyUpdate(ctx, std.fs.cwd(), arg, stat.kind);
    }
}
