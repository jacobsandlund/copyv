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
    const sha_with_path = blob_it.next().?;
    var path_parts = std.mem.splitScalar(u8, sha_with_path, '/');
    _ = path_parts.next(); // skip sha
    const path = path_parts.rest();
    const repo = original_host["https://github.com/".len..];
    const old_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}", .{ repo, sha_with_path });
    defer allocator.free(old_url);
    const new_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/main/{s}", .{ repo, path });
    defer allocator.free(new_url);

    const old_file_name = "tmp/old_file";
    const new_file_name = "tmp/new_file";

    try fetchFile(allocator, old_url, old_file_name);
    try fetchFile(allocator, new_url, new_file_name);

    var stderr = std.ArrayList(u8).empty;
    var stdout = std.ArrayList(u8).empty;

    var child_proc = std.process.Child.init(
        &[_][]const u8{ "git", "diff", "--no-index", old_file_name, new_file_name },
        allocator,
    );
    child_proc.stdout_behavior = .Pipe;
    child_proc.stderr_behavior = .Pipe;
    try child_proc.spawn();
    try child_proc.collectOutput(allocator, &stdout, &stderr, 1_000_000);
    const stdout_slice = try stdout.toOwnedSlice(allocator);
    const exit_code = try child_proc.wait();
    _ = exit_code;

    var lines = std.mem.splitScalar(u8, line_numbers, '-');
    const start_str = std.mem.trim(u8, lines.next().?, "L");
    const end_str = std.mem.trim(u8, lines.next().?, "L");
    const start = try std.fmt.parseInt(usize, start_str, 10);
    const end = try std.fmt.parseInt(usize, end_str, 10);

    var diff_lines = std.mem.splitScalar(u8, stdout_slice, '\n');
    var should_print = false;
    while (diff_lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            const trimmed = std.mem.trim(u8, line["@@".len..], " \t");
            var header_parts = std.mem.splitScalar(u8, trimmed, ' ');
            const old_range = header_parts.next().?;
            var range_parts = std.mem.splitScalar(u8, old_range, ',');
            const range_start_str = range_parts.next().?;
            const diff_start = try std.fmt.parseInt(usize, range_start_str["-".len..], 10);
            const range_len_str = range_parts.next().?;
            const len = try std.fmt.parseInt(usize, range_len_str, 10);
            const diff_end = diff_start + len;

            if ((diff_start <= start and end <= diff_end) or
                (start <= diff_start and diff_end <= end) or
                (diff_start < start and start < diff_end) or
                (start < diff_start and diff_start < end))
            {
                should_print = true;
            } else {
                should_print = false;
            }
        }

        if (should_print) {
            std.debug.print("{s}\n", .{line});
        }
    }
}

fn fetchFile(allocator: std.mem.Allocator, url: []const u8, path: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(&buffer);
    const writer = &file_writer.interface;

    var client = std.http.Client{ .allocator = allocator };
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = writer,
    });
}

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}).init;
    const allocator = debug_allocator.allocator();
    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    try doStuff(allocator, dir);
}
