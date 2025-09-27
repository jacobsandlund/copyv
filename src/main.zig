const std = @import("std");

const URL_TAG = "// copyv: ";

fn doStuff(allocator: std.mem.Allocator, dir: std.fs.Dir) !void {
    var it = dir.iterate();
    var buff: [256]u8 = undefined;
    while (try it.next()) |entry| {
        if (entry.name.len > 1 and entry.name[0] == '.') continue;

        std.debug.print("entry.name={s}\n", .{entry.name});

        if (entry.kind == .directory) {
            var subdir = try dir.openDir(entry.name, .{ .iterate = true });
            defer subdir.close();
            try doStuff(allocator, subdir);
        } else if (entry.kind == .file) {
            var file = try dir.openFile(entry.name, .{});
            defer file.close();
            var file_rdr = file.reader(&buff);
            var rdr = &file_rdr.interface;
            const bytes = try rdr.allocRemaining(allocator, .unlimited);
        }
    }
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const allocator = debug_allocator.allocator();
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    try doStuff(allocator, dir);
}
