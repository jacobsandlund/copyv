const std = @import("std");

const Action = enum {
    pull,
    get,
    get_frozen,
    check_frozen,
};

const FileTypeInfo = struct {
    comments: []const []const u8,
    common_indent_width: u8,
};

const file_type_info_map = std.StaticStringMap(FileTypeInfo).initComptime(.{
    .{ ".zig", FileTypeInfo{ .comments = &[_][]const u8{"//"}, .common_indent_width = 4 } },
    .{ ".jl", FileTypeInfo{ .comments = &[_][]const u8{"#"}, .common_indent_width = 4 } },
    .{ ".js", FileTypeInfo{ .comments = &[_][]const u8{"//"}, .common_indent_width = 2 } },
});

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
    var maybe_in_frozen_chunk = false;

    var updated_bytes = try std.ArrayList(u8).initCapacity(allocator, bytes.len + 1024);
    var indent: ?Indent = null;

    while (lines.next()) |line| : (line_number += 1) {
        if (mightMatchTag(line)) {
            if (try updateChunk(
                allocator,
                file_name,
                line_number,
                &updated_bytes,
                &lines,
                line,
                &indent,
                file_type_info,
                &maybe_in_frozen_chunk,
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

// If the tag matches, this returns the comment including whitespace.
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
                const indent_start = line.len - line_trimmed.len;
                const tag_whitespace = tag.len - tag_trimmed.len;
                const prefix_len = indent_start + comment.len + tag_whitespace + copyv_tag.len;
                const prefix = line[0..prefix_len];
                const file_indent = lazy_file_indent.* orelse blk: {
                    const indent = getIndent(file_bytes, file_type_info.common_indent_width);
                    lazy_file_indent.* = indent;
                    break :blk indent;
                };

                return .{
                    .prefix = prefix,
                    .indent = .{
                        .start = indent_start,
                        .width = file_indent.width,
                        .char = file_indent.char,
                    },
                };
            }
        }
    }

    return null;
}

fn matchesEndTag(file_name: []const u8, line_number: usize, line: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, line, prefix)) return false;

    const trimmed = std.mem.trimStart(u8, line[prefix.len..], line_whitespace);
    if (!std.mem.startsWith(u8, trimmed, "e")) { // "end"
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
    lazy_file_indent: *?Indent,
    file_type_info: FileTypeInfo,
    maybe_in_frozen_chunk: *bool,
) !bool {
    // Check if matches tag
    const maybe_match = matchesTag(
        current_line,
        file_type_info,
        lazy_file_indent,
        lines.buffer,
    );
    if (maybe_match == null) return false;
    const match = maybe_match.?;
    const prefix = match.prefix;
    const indent = match.indent;

    // Get the files from remote

    const line_payload = std.mem.trim(u8, current_line[prefix.len..], line_whitespace);
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
    } else if (std.mem.startsWith(u8, first_arg, "e")) { // end
        if (maybe_in_frozen_chunk.*) {
            return false;
        } else {
            std.debug.panic("{s}[{d}]: Unexpected copyv: end, outside of a copyv chunk\n", .{ file_name, start_line_number });
        }
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
        maybe_in_frozen_chunk.* = true;

        if (ref.len != 40) {
            std.debug.panic("{s}[{d}]: Frozen copyv line must point to a commit SHA\n", .{
                file_name,
                start_line_number,
            });
        }

        if (std.mem.eql(u8, first_arg, "frozen")) {
            return false;
        } else {
            const updated_line = try std.fmt.allocPrint(
                allocator,
                "{s} frozen {s}",
                .{ prefix, url_with_line_numbers },
            );
            try updated_bytes.appendSlice(allocator, updated_line);
            try maybeAppendNewline(updated_bytes, allocator, lines);
            return true;
        }
    } else {
        maybe_in_frozen_chunk.* = false;
    }

    const path = path_parts.rest();
    const repo = original_host["https://github.com/".len..];
    var line_numbers = std.mem.splitScalar(u8, line_numbers_str, '-');
    const base_start_str = line_numbers.next().?["L".len..];
    const base_end_str = line_numbers.next().?["L".len..];
    const base_start = try std.fmt.parseInt(usize, base_start_str, 10);
    const base_end = try std.fmt.parseInt(usize, base_end_str, 10);

    const base_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}", .{ repo, ref_with_path });
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
        try updated_bytes.appendSlice(allocator, updated_line);
        try updated_bytes.append(allocator, '\n');
        try matchIndent(allocator, updated_bytes, base_bytes, indent, file_type_info.common_indent_width);
        try maybeAppendNewline(updated_bytes, allocator, lines);

        return true;
    }

    const latest_sha = try fetchLatestCommitSha(allocator, repo, ref);
    const new_url = try std.fmt.allocPrint(allocator, "https://raw.githubusercontent.com/{s}/{s}/{s}", .{ repo, latest_sha, path });
    const new_file_bytes = try fetchFile(allocator, new_url);

    // Diff the files

    const base_file_name = "tmp/base_file";
    const new_file_name = "tmp/new_file";
    try std.fs.cwd().writeFile(.{ .sub_path = base_file_name, .data = base_file_bytes });
    try std.fs.cwd().writeFile(.{ .sub_path = new_file_name, .data = new_file_bytes });

    const stdout_slice = try runCommand(
        allocator,
        &[_][]const u8{ "git", "diff", "--no-index", base_file_name, new_file_name },
    );

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
    var base_indented = try std.ArrayList(u8).initCapacity(allocator, base_bytes.len);
    var new_indented = try std.ArrayList(u8).initCapacity(allocator, new_bytes.len);
    try matchIndent(allocator, &base_indented, base_bytes, indent, file_type_info.common_indent_width);
    try matchIndent(allocator, &new_indented, new_bytes, indent, file_type_info.common_indent_width);
    try std.fs.cwd().writeFile(.{ .sub_path = base_file_name, .data = base_indented.items });
    try std.fs.cwd().writeFile(.{ .sub_path = new_file_name, .data = new_indented.items });

    var updated_chunk: []const u8 = new_indented.items;
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
            if (std.mem.eql(u8, maybe_chunk, base_indented.items)) {
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
        if (!std.mem.eql(u8, current_chunk, base_indented.items)) {
            const current_file_name = "tmp/current_file";
            try std.fs.cwd().writeFile(.{ .sub_path = current_file_name, .data = current_chunk });

            const conflict_style_output = try runCommand(
                allocator,
                &[_][]const u8{ "git", "config", "--get", "merge.conflictstyle" },
            );
            const conflict_style = std.mem.trim(u8, conflict_style_output, line_whitespace);
            var merge_args = try std.ArrayList([]const u8).initCapacity(allocator, 7);
            merge_args.appendSliceAssumeCapacity(&[_][]const u8{ "git", "merge-file", "-p" });

            if (std.mem.eql(u8, conflict_style, "diff3")) {
                merge_args.appendAssumeCapacity("--diff3");
            } else if (std.mem.eql(u8, conflict_style, "zdiff3")) {
                merge_args.appendAssumeCapacity("--zdiff3");
            }

            merge_args.appendSliceAssumeCapacity(&[_][]const u8{ current_file_name, base_file_name, new_file_name });

            updated_chunk = try runCommand(allocator, merge_args.items);
        }
    }

    // Write back bytes

    const updated_url = try std.fmt.allocPrint(
        allocator,
        "{s} {s}/blob/{s}/{s}#L{d}-L{d}",
        .{ prefix, original_host, latest_sha, path, new_start, new_end },
    );
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

const max_output_bytes = 100_000_000;

fn runCommand(allocator: std.mem.Allocator, args: []const []const u8) ![]const u8 {
    var stderr = std.ArrayList(u8).empty;
    var stdout = std.ArrayList(u8).empty;
    var child_proc = std.process.Child.init(args, allocator);
    child_proc.stdout_behavior = .Pipe;
    child_proc.stderr_behavior = .Pipe;
    try child_proc.spawn();
    try child_proc.collectOutput(allocator, &stdout, &stderr, max_output_bytes);
    _ = try child_proc.wait();
    return try stdout.toOwnedSlice(allocator);
}

fn fetchLatestCommitSha(
    allocator: std.mem.Allocator,
    repo: []const u8,
    ref: []const u8,
) ![]const u8 {
    const latest_ref = if (ref.len == 40) "HEAD" else ref;
    const api_url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/commits/{s}", .{ repo, latest_ref });

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

const shift_count_threshold = 8;
const space_count_threshold = 5;
const tab_count_threshold = 3;
const max_indent_width = 16;

fn getIndent(bytes: []const u8, file_type_common_indent: u8) Indent {
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
            if (char == ' ') {
                break index;
            } else {
                tab_count = std.mem.count(u8, line[0..index], "\t");
                space_count = std.mem.count(u8, line[0..index], " ");

                // Note: this does not consider spaces that have no impact on
                // the indentation because they are followed by tabs, but for
                // well-formed whitespace, that shouldn't be the case.
                break tab_count * file_type_common_indent + space_count;
            }
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
    file_type_common_indent: u8,
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
