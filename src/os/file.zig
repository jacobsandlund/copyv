// cpv: track https://github.com/ghostty-org/ghostty/blob/05b580911577ae86e7a29146fac29fb368eab536/src/os/file.zig#L1-L5
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const log = std.log.scoped(.os);
// cpv: end

/// cpv: track https://github.com/ghostty-org/ghostty/blob/05b580911577ae86e7a29146fac29fb368eab536/src/os/file.zig#L56-L79
/// Return the recommended path for temporary files.
/// This may not actually allocate memory, use freeTmpDir to properly
/// free the memory when applicable.
pub fn allocTmpDir(allocator: std.mem.Allocator) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        // TODO: what is a good fallback path on windows?
        const v = std.process.getenvW(std.unicode.utf8ToUtf16LeStringLiteral("TMP")) orelse return null;
        return std.unicode.utf16LeToUtf8Alloc(allocator, v) catch |e| {
            log.warn("failed to convert temp dir path from windows string: {}", .{e});
            return null;
        };
    }
    if (posix.getenv("TMPDIR")) |v| return v;
    if (posix.getenv("TMP")) |v| return v;
    return "/tmp";
}

/// Free a path returned by tmpDir if it allocated memory.
/// This is a "no-op" for all platforms except windows.
pub fn freeTmpDir(allocator: std.mem.Allocator, dir: []const u8) void {
    if (builtin.os.tag == .windows) {
        allocator.free(dir);
    }
}
// cpv: end
