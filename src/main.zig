const std = @import("std");

const URL_TAG = "// copyv: ";

fn doStuff(allocator: std.mem.Allocator, dir: std.fs.Dir) !void {
    var it = dir.iterate();
    var buff: [256]u8 = undefined;
    while (try it.next()) |entry| {
        if (entry.name.len > 1 and entry.name[0] == '.') continue;

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
            var lines = std.mem.splitScalar(u8, bytes, '\n');

            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \t");
                if (std.mem.startsWith(u8, trimmed, URL_TAG)) {
                    try doMoreStuff(allocator, trimmed);
                }
            }
        }
    }
}

fn doMoreStuff(allocator: std.mem.Allocator, original_line: []const u8) !void {
    var parts = std.mem.splitScalar(u8, original_line, ':');
    _ = parts.next(); // skip copyv
    const url_with_line_numbers = std.mem.trim(u8, parts.rest(), " \t");
    var url_parts = std.mem.splitScalar(u8, url_with_line_numbers, '#');
    const original_url = url_parts.next().?;
    const line_numbers = url_parts.rest();
    var blob_it = std.mem.splitSequence(u8, original_url, "/blob/");
    const original_host = blob_it.next().?;
    const path = blob_it.next().?;
    const repo = original_host["https://github.com/".len..];
    const url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}", .{ repo, path });
    defer allocator.free(url);

    std.debug.print("url={s}\n", .{url});
    _ = line_numbers;

    var allocating = std.Io.Writer.Allocating.init(allocator);
    const writer = &allocating.writer;

    var client = std.http.Client{ .allocator = allocator };
    const status_code = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = writer,
    });

    std.debug.print("code={}\n", .{status_code});
    std.debug.print("out_buffer={s}\n", .{try allocating.toOwnedSlice()});
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const allocator = debug_allocator.allocator();
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    try doStuff(allocator, dir);
}
