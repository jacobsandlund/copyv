const std = @import("std");

fn doStuff(dir: std.fs.Dir) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.name.len > 1 and entry.name[0] == '.') continue;

        std.debug.print("entry.name={s}\n", .{entry.name});

        if (entry.kind == .directory) {
            try doStuff(try dir.openDir(entry.name, .{ .iterate = true }));
        }
    }
}

pub fn main() !void {
    const dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    try doStuff(dir);
}
