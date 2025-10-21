const std = @import("std");

const URL_TAG = "// copyv: ";

fn recursivelyUpdate(arena: *std.heap.ArenaAllocator, dir: std.fs.Dir) !void {
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.name.len > 1 and entry.name[0] == '.') continue;

        if (entry.kind == .directory) {
            var subdir = try dir.openDir(entry.name, .{ .iterate = true });
            defer subdir.close();
            try recursivelyUpdate(arena, subdir);
        } else if (entry.kind == .file) {
            const allocator = arena.allocator();
            try updateFile(allocator, dir, entry.name);
            _ = arena.reset(.{ .retain_with_limit = 1024 * 1024 });
        }
    }
}

fn updateFile(allocator: std.mem.Allocator, dir: std.fs.Dir, name: []const u8) !void {
    var file = try dir.openFile(name, .{});
    defer file.close();
    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);
    var reader = &file_reader.interface;
    const bytes = try reader.allocRemaining(allocator, .unlimited);
    var lines = std.mem.splitScalar(u8, bytes, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, URL_TAG)) {
            try updateChunk(allocator, trimmed);
        }
    }
}

fn updateChunk(allocator: std.mem.Allocator, original_line: []const u8) !void {
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

    const old_file_bytes = try fetchFile(allocator, old_url, old_file_name);
    const new_file_bytes = try fetchFile(allocator, new_url, new_file_name);

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
    _ = try child_proc.wait();

    var lines = std.mem.splitScalar(u8, line_numbers, '-');
    const old_start_str = std.mem.trim(u8, lines.next().?, "L");
    const old_end_str = std.mem.trim(u8, lines.next().?, "L");
    const old_start = try std.fmt.parseInt(usize, old_start_str, 10);
    const old_end = try std.fmt.parseInt(usize, old_end_str, 10);

    var diff_lines = std.mem.splitScalar(u8, stdout_slice, '\n');
    var old_line: usize = 0;
    var new_line: usize = 0;
    var new_start: usize = 0;
    var new_end: usize = 0;
    var old_range: GitRange = .{ .start = 0, .len = 0 };
    var new_range: GitRange = .{ .start = 0, .len = 0 };
    for (0..4) |_| _ = diff_lines.next(); // Skip diff header
    while (diff_lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "@@")) {
            std.debug.assert(old_line == old_range.start + old_range.len);
            std.debug.assert(new_line == new_range.start + new_range.len);
            var header_parts = std.mem.splitScalar(u8, line, ' ');
            _ = header_parts.next().?; // skip @@
            old_range = try parseRange(header_parts.next().?);
            new_range = try parseRange(header_parts.next().?);
            old_line = old_range.start;
            new_line = new_range.start;

            if (new_start == 0 and old_line > old_start) {
                const delta: usize = old_line - old_start;
                new_start = new_line - delta;
            } else if (new_end == 0 and old_line > old_end) {
                const delta: usize = old_line - old_end;
                new_end = new_line - delta;
            }
        } else if (std.mem.startsWith(u8, line, "-")) {
            old_line += 1;
        } else if (std.mem.startsWith(u8, line, "+")) {
            new_line += 1;
        } else {
            // Either it's a shared line or the last empty line of the diff
            std.debug.assert(std.mem.startsWith(u8, line, " ") or diff_lines.peek() == null);
            old_line += 1;
            new_line += 1;
        }

        if (old_line == old_start and new_start == 0) {
            new_start = new_line;
        }
        if (old_line == old_end) {
            new_end = new_line;
        }
    }

    if (new_line == 0) {
        // There was no diff
        new_start = old_start;
        new_end = old_end;
    } else if (new_start == 0) {
        // The only diffs were before this section
        std.debug.assert(old_line < old_start);
        const delta: isize = @intCast(new_line - old_line);
        new_start = @intCast(@as(isize, @intCast(old_start)) + delta);
        new_end = @intCast(@as(isize, @intCast(old_end)) + delta);
    } else if (new_end == 0) {
        // The only diffs were before the end of this section
        std.debug.assert(old_line < old_end);
        const delta: isize = @intCast(new_line - old_line);
        new_end = @intCast(@as(isize, @intCast(old_end)) + delta);
    }

    try writeLines(old_file_bytes, old_file_name, old_start, old_end);
    try writeLines(new_file_bytes, new_file_name, new_start, new_end);

    child_proc = std.process.Child.init(
        &[_][]const u8{ "delta", old_file_name, new_file_name },
        allocator,
    );
    child_proc.stdout_behavior = .Inherit;
    child_proc.stderr_behavior = .Inherit;
    try child_proc.spawn();
    _ = try child_proc.wait();
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

fn fetchFile(allocator: std.mem.Allocator, url: []const u8, path: []const u8) ![]const u8 {
    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    var client = std.http.Client{ .allocator = allocator };
    _ = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &aw.writer,
    });

    const bytes = try aw.toOwnedSlice();
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes });
    return bytes;
}

fn writeLines(bytes: []const u8, path: []const u8, start_line: usize, end_line: usize) !void {
    var start: usize = undefined;
    var end: usize = undefined;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var i: usize = 1;

    while (lines.next()) |line| : (i += 1) {
        if (i == start_line) {
            start = line.ptr - bytes.ptr;
        } else if (i == end_line) {
            end = line.ptr - bytes.ptr + line.len;
        }
    }

    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = bytes[start..end] });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var dir = try std.fs.cwd().openDir(".", .{ .iterate = true });
    defer dir.close();
    try recursivelyUpdate(&arena, dir);
}
