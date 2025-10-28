const std = @import("std");

const max_output_bytes = 100_000_000;

const Action = enum {
    pull,
    get,
    get_frozen,
    check_frozen,
};

fn recursivelyUpdate(arena: *std.heap.ArenaAllocator, parent_dir: std.fs.Dir, name: []const u8, kind: std.fs.File.Kind) !void {
    if (kind == .directory) {
        if (name.len > 1 and name[0] == '.') return;

        var dir = try parent_dir.openDir(name, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            try recursivelyUpdate(arena, dir, entry.name, entry.kind);
        }
    } else if (kind == .file) {
        try updateFile(arena, parent_dir, name);
    }
}

fn updateFile(arena: *std.heap.ArenaAllocator, dir: std.fs.Dir, file_name: []const u8) !void {
    if (!std.mem.endsWith(u8, file_name, ".zig") and
        !std.mem.endsWith(u8, file_name, ".jl")) return;

    const possible_comments: []const []const u8 = if (std.mem.endsWith(u8, file_name, ".jl")) &[_][]const u8{"#"} else &[_][]const u8{"//"};

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

    var updated_bytes = try std.ArrayList(u8).initCapacity(allocator, bytes.len + 1024);

    while (lines.next()) |line| : (line_number += 1) {
        if (mightMatchTag(line)) {
            if (try updateChunk(
                allocator,
                file_name,
                line_number,
                &updated_bytes,
                &lines,
                line,
                possible_comments,
            )) {
                has_update = true;
            } else {
                try updated_bytes.appendSlice(allocator, line);
                try maybeAppendNewline(&updated_bytes, allocator, &lines);
            }
        } else {
            try updated_bytes.appendSlice(allocator, line);
            try maybeAppendNewline(&updated_bytes, allocator, &lines);
        }
    }

    if (has_update) {
        try dir.writeFile(.{ .sub_path = file_name, .data = updated_bytes.items });
    }
}

fn maybeAppendNewline(
    bytes: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    lines: *std.mem.SplitIterator(u8, .scalar),
) !void {
    if (lines.peek() != null) {
        try bytes.append(allocator, '\n');
    }
}

const COPYV_TAG = "copyv:";
const COPYV_END = "end";

fn mightMatchTag(line: []const u8) bool {
    return std.mem.indexOf(u8, line, COPYV_TAG) != null;
}

const Match = struct {
    prefix: []const u8,
    indent: usize,
};

// If the tag matches, this returns the comment including whitespace.
fn matchesTag(line: []const u8, possible_comments: []const []const u8) ?Match {
    const line_trimmed = std.mem.trimStart(u8, line, &std.ascii.whitespace);
    for (possible_comments) |comment| {
        if (std.mem.startsWith(u8, line_trimmed, comment)) {
            const tag = line_trimmed[comment.len..];
            const tag_trimmed = std.mem.trimStart(u8, tag, &std.ascii.whitespace);
            if (std.mem.startsWith(u8, tag_trimmed, COPYV_TAG)) {
                const indent = line.len - line_trimmed.len;
                const tag_whitespace = tag.len - tag_trimmed.len;
                const prefix_len = indent + comment.len + tag_whitespace + COPYV_TAG.len;
                const prefix = line[0..prefix_len];
                return .{ .prefix = prefix, .indent = indent };
            }
        }
    }

    return null;
}

fn matchesEndTag(file_name: []const u8, line_number: usize, line: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, line, prefix)) return false;

    const trimmed = std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace);
    if (!std.mem.eql(u8, trimmed, COPYV_END)) {
        std.debug.panic(
            "{s}[{d}]: Expected copyv: end, but got another copyv line while still in a copyv section\n",
            .{
                file_name,
                line_number,
            },
        );
    }

    return true;
}

fn updateChunk(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    start_line_number: usize,
    updated_bytes: *std.ArrayList(u8),
    lines: *std.mem.SplitIterator(u8, .scalar),
    current_line: []const u8,
    possible_comments: []const []const u8,
) !bool {
    // Check if matches tag
    const maybe_match = matchesTag(current_line, possible_comments);
    if (maybe_match == null) return false;
    const match = maybe_match.?;
    const prefix = match.prefix;
    const indent = match.indent;
    _ = indent;

    // Get the files from remote

    const line_payload = std.mem.trim(u8, current_line[prefix.len..], &std.ascii.whitespace);
    var line_args = std.mem.splitScalar(u8, line_payload, ' ');
    const first_arg = line_args.first();
    var action: Action = undefined;
    var url_with_line_numbers: []const u8 = undefined;

    if (std.mem.startsWith(u8, first_arg, "g")) { // get, go, g
        if (line_args.peek()) |peek| {
            if (std.mem.startsWith(u8, peek, "fr")) { // freeze, frozen, fr
                action = .get_frozen;
                _ = line_args.next(); // skip fr[ozen]
            } else {
                action = .get;
            }
        } else {
            std.debug.panic("{s}[{d}]: Expected an argument after get\n", .{ file_name, start_line_number });
        }
        url_with_line_numbers = line_args.rest();
    } else if (std.mem.startsWith(u8, first_arg, "fr")) { // freeze, frozen, fr
        action = .check_frozen;
        url_with_line_numbers = line_args.rest();
    } else {
        action = .pull;
        url_with_line_numbers = first_arg;
        std.debug.assert(std.mem.eql(u8, line_args.rest(), ""));
    }

    var url_parts = std.mem.splitScalar(u8, url_with_line_numbers, '#');
    const original_url = url_parts.next().?;
    const line_numbers_str = url_parts.rest();
    var blob_it = std.mem.splitSequence(u8, original_url, "/blob/");
    const original_host = blob_it.next().?;
    const ref_with_path = blob_it.next().?;
    var path_parts = std.mem.splitScalar(u8, ref_with_path, '/');
    const ref = path_parts.next().?;

    if (action == .check_frozen) {
        if (ref.len != 40) {
            std.debug.panic("{s}[{d}]: Frozen copyv line must point to a commit SHA\n", .{
                file_name,
                start_line_number,
            });
        }
        return false;
    }

    const path = path_parts.rest();
    const repo = original_host["https://github.com/".len..];
    var line_numbers = std.mem.splitScalar(u8, line_numbers_str, '-');
    const base_start_str = std.mem.trim(u8, line_numbers.next().?, "L");
    const base_end_str = std.mem.trim(u8, line_numbers.next().?, "L");
    const base_start = try std.fmt.parseInt(usize, base_start_str, 10);
    const base_end = try std.fmt.parseInt(usize, base_end_str, 10);

    const base_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}", .{ repo, ref_with_path });
    defer allocator.free(base_url);
    const base_file_bytes = try fetchFile(allocator, base_url);

    if (action == .get_frozen) {
        const frozen_sha = if (ref.len == 40)
            ref
        else
            try fetchLatestCommitSha(allocator, repo, ref);
        const base_bytes = try getLines(base_file_bytes, base_start, base_end);
        const updated_line = try std.fmt.allocPrint(
            allocator,
            "{s} frozen {s}/blob/{s}/{s}#{s}",
            .{ prefix, original_host, frozen_sha, path, line_numbers_str },
        );
        defer allocator.free(updated_line);
        try updated_bytes.appendSlice(allocator, updated_line);
        try updated_bytes.append(allocator, '\n');
        try updated_bytes.appendSlice(allocator, base_bytes);

        try maybeAppendNewline(updated_bytes, allocator, lines);

        return true;
    }

    const latest_sha = try fetchLatestCommitSha(allocator, repo, ref);
    defer allocator.free(latest_sha);
    const new_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}", .{ repo, latest_sha, path });
    defer allocator.free(new_url);
    const new_file_bytes = try fetchFile(allocator, new_url);

    // Diff the files

    const base_file_name = "tmp/base_file";
    const new_file_name = "tmp/new_file";
    try std.fs.cwd().writeFile(.{ .sub_path = base_file_name, .data = base_file_bytes });
    try std.fs.cwd().writeFile(.{ .sub_path = new_file_name, .data = new_file_bytes });

    var stderr = std.ArrayList(u8).empty;
    var stdout = std.ArrayList(u8).empty;

    var child_proc = std.process.Child.init(
        &[_][]const u8{ "git", "diff", "--no-index", base_file_name, new_file_name },
        allocator,
    );
    child_proc.stdout_behavior = .Pipe;
    child_proc.stderr_behavior = .Pipe;
    try child_proc.spawn();
    try child_proc.collectOutput(allocator, &stdout, &stderr, max_output_bytes);
    const stdout_slice = try stdout.toOwnedSlice(allocator);
    _ = try child_proc.wait();

    // Check if diff is in the chunk

    var diff_lines = std.mem.splitScalar(u8, stdout_slice, '\n');
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
    try std.fs.cwd().writeFile(.{ .sub_path = base_file_name, .data = base_bytes });
    try std.fs.cwd().writeFile(.{ .sub_path = new_file_name, .data = new_bytes });

    var updated_chunk: []const u8 = new_bytes;
    var include_end_tag = false;

    // Get the current chunk
    if (action == .pull) {
        const chunk_len = base_end - base_start + 1;
        const current_bytes = lines.buffer;
        const current_start = current_line.ptr - current_bytes.ptr + current_line.len + 1;
        var line_number = start_line_number;

        const current_end = for (0..chunk_len - 1) |_| {
            if (lines.next()) |line| {
                line_number += 1;
                if (matchesEndTag(file_name, line_number, line, prefix)) {
                    include_end_tag = true;
                    break line.ptr - current_bytes.ptr - 1;
                }
            } else break current_bytes.len;
        } else end_blk: {
            const maybe_end = maybe_blk: {
                if (lines.next()) |line| {
                    line_number += 1;
                    if (matchesEndTag(file_name, line_number, line, prefix)) {
                        include_end_tag = true;
                        break :end_blk line.ptr - current_bytes.ptr - 1;
                    } else {
                        break :maybe_blk line.ptr - current_bytes.ptr + line.len;
                    }
                } else break :end_blk current_bytes.len;
            };

            const maybe_chunk = current_bytes[current_start..maybe_end];
            if (std.mem.eql(u8, maybe_chunk, base_bytes)) {
                break :end_blk maybe_end;
            }

            while (lines.next()) |line| : (line_number += 1) {
                if (matchesEndTag(file_name, line_number, line, prefix)) {
                    include_end_tag = true;
                    break :end_blk line.ptr - current_bytes.ptr - 1;
                }
            } else break :end_blk current_bytes.len;
        };

        // Determine updated chunk bytes

        const current_chunk = current_bytes[current_start..current_end];
        if (!std.mem.eql(u8, current_chunk, base_bytes)) {
            const current_file_name = "tmp/current_file";
            try std.fs.cwd().writeFile(.{ .sub_path = current_file_name, .data = current_chunk });

            stderr = std.ArrayList(u8).empty;
            stdout = std.ArrayList(u8).empty;
            child_proc = std.process.Child.init(
                &[_][]const u8{ "git", "config", "--get", "merge.conflictstyle" },
                allocator,
            );
            child_proc.stdout_behavior = .Pipe;
            child_proc.stderr_behavior = .Pipe;
            try child_proc.spawn();
            try child_proc.collectOutput(allocator, &stdout, &stderr, max_output_bytes);
            _ = try child_proc.wait();
            const conflict_style = std.mem.trim(u8, try stdout.toOwnedSlice(allocator), &std.ascii.whitespace);
            defer allocator.free(conflict_style);

            stderr = std.ArrayList(u8).empty;
            stdout = std.ArrayList(u8).empty;

            var merge_args = try std.ArrayList([]const u8).initCapacity(allocator, 7);
            merge_args.appendSliceAssumeCapacity(&[_][]const u8{ "git", "merge-file", "-p" });
            if (std.mem.eql(u8, conflict_style, "diff3")) {
                merge_args.appendAssumeCapacity("--diff3");
            } else if (std.mem.eql(u8, conflict_style, "zdiff3")) {
                merge_args.appendAssumeCapacity("--zdiff3");
            }
            merge_args.appendSliceAssumeCapacity(&[_][]const u8{ current_file_name, base_file_name, new_file_name });

            child_proc = std.process.Child.init(
                merge_args.items,
                allocator,
            );
            child_proc.stdout_behavior = .Pipe;
            child_proc.stderr_behavior = .Pipe;
            try child_proc.spawn();
            try child_proc.collectOutput(allocator, &stdout, &stderr, max_output_bytes);
            const merged_bytes = try stdout.toOwnedSlice(allocator);
            _ = try child_proc.wait();
            updated_chunk = merged_bytes;
        }
    }

    // Write back bytes

    const updated_url = try std.fmt.allocPrint(
        allocator,
        "{s} {s}/blob/{s}/{s}#L{d}-L{d}",
        .{ prefix, original_host, latest_sha, path, new_start, new_end },
    );
    defer allocator.free(updated_url);
    try updated_bytes.appendSlice(allocator, updated_url);
    try updated_bytes.append(allocator, '\n');
    try updated_bytes.appendSlice(allocator, updated_chunk);

    if (include_end_tag) {
        try updated_bytes.append(allocator, '\n');
        const end_line = try std.fmt.allocPrint(
            allocator,
            "{s} end",
            .{prefix},
        );
        defer allocator.free(end_line);
        try updated_bytes.appendSlice(allocator, end_line);
    }

    try maybeAppendNewline(updated_bytes, allocator, lines);

    return true;
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

fn fetchLatestCommitSha(
    allocator: std.mem.Allocator,
    repo: []const u8,
    ref: []const u8,
) ![]const u8 {
    const latest_ref = if (ref.len == 40) "HEAD" else ref;
    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/commits/{s}", .{ repo, latest_ref });
    defer allocator.free(api_url);

    var aw = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    var client = std.http.Client{ .allocator = allocator };
    _ = try client.fetch(.{
        .location = .{ .url = api_url },
        .response_writer = &aw.writer,
    });

    const json_bytes = try aw.toOwnedSlice();
    defer allocator.free(json_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const sha = parsed.value.object.get("sha").?.string;
    return try allocator.dupe(u8, sha);
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
        } else if (i == end_line) {
            end = line.ptr - bytes.ptr + line.len;
        }
    }

    return bytes[start..end];
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const allocator = arena.allocator();
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

    try recursivelyUpdate(&arena, std.fs.cwd(), name, kind);
}
