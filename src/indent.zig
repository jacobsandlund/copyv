const std = @import("std");

pub const DebugIndent = enum { off, basic, verbose };
pub const FileTypeIndentDefault = struct { width: u8, char: u8 };
pub const Indent = struct {
    enabled: bool = true,
    start_slice: []const u8 = "",
    start_width: ?usize = null,
    width: ?usize = null,
    char: ?u8 = null,
};
pub const Context = struct {
    file_type: FileTypeIndentDefault,
    debug: DebugIndent = .off,
    name: []const u8 = "",
    line_number: usize = 0,
};

const shift_count_threshold = 6;
const indent_char_count_threshold = 10;
const max_lines_to_check = 1000;
const indent_char_count_min = 4;
const max_indent_width = 16;
const minimum_detected_shift_count = 3;
const line_whitespace = " \t\r";

pub fn getIndentStart(whitespace: []const u8, width: usize) usize {
    return std.mem.count(u8, whitespace, "\t") * width +
        std.mem.count(u8, whitespace, " ");
}

pub fn detect(context: Context, indent: *Indent, bytes: []const u8) void {
    if (indent.char == null) detectChar(context, indent, bytes);
    if (indent.start_width == null) detectStart(context, indent, bytes);
    if (indent.width == null) detectWidth(context, indent, bytes);
}

fn detectChar(context: Context, indent: *Indent, bytes: []const u8) void {
    const Reason = enum { threshold, majority, file_type_default };
    var reason: Reason = undefined;
    var spaces_count: usize = 0;
    var tabs_count: usize = 0;
    var i: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    const found: ?u8 = while (lines.next()) |line| : (i += 1) {
        if (i >= max_lines_to_check) break null;
        if (std.mem.startsWith(u8, line, " ")) {
            spaces_count += 1;
            if (spaces_count >= indent_char_count_threshold) {
                reason = .threshold;
                break ' ';
            }
        } else if (std.mem.startsWith(u8, line, "\t")) {
            tabs_count += 1;
            if (tabs_count >= indent_char_count_threshold) {
                reason = .threshold;
                break '\t';
            }
        }
    } else null;
    indent.char = found orelse blk: {
        if (spaces_count + tabs_count >= indent_char_count_min) {
            reason = .majority;
            if (tabs_count > spaces_count) break :blk '\t';
            if (spaces_count > tabs_count) break :blk ' ';
        }
        reason = .file_type_default;
        break :blk context.file_type.char;
    };
    if (context.debug != .off) {
        std.log.info("{s}[{d}]: indent char={s} ({t}, spaces={d}, tabs={d}, lines={d})", .{
            context.name, context.line_number, if (indent.char.? == ' ') "space" else "tab",
            reason,       spaces_count,        tabs_count,
            i,
        });
    }
}

fn detectStart(context: Context, indent: *Indent, bytes: []const u8) void {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var i: usize = 0;
    while (lines.next()) |line| : (i += 1) {
        if (i >= max_lines_to_check) break;
        if (std.mem.indexOfNone(u8, line, line_whitespace)) |index| {
            indent.start_width = getIndentStart(line[0..index], context.file_type.width);
            break;
        }
    }
    if (indent.start_width == null) indent.start_width = 0;
    if (context.debug != .off) {
        std.log.info("{s}[{d}]: indent start_width={d} (lines={d})", .{
            context.name, context.line_number, indent.start_width.?, i,
        });
    }
}

fn detectWidth(context: Context, indent: *Indent, bytes: []const u8) void {
    const Reason = enum { tab_file_type_default, threshold, insufficient_evidence, max_count, max_count_tie_breaker, tie_file_type_default };
    var reason: Reason = undefined;
    var indent_counts: [max_indent_width]usize = @splat(0);
    var deindent_counts: [max_indent_width]usize = @splat(0);
    var i: usize = 0;
    if (indent.char.? == '\t') {
        indent.width = context.file_type.width;
        reason = .tab_file_type_default;
    } else {
        var last_indent: usize = 0;
        var last_content: []const u8 = "a";
        var last_line: []const u8 = "";
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        const threshold_width = while (lines.next()) |line| : (i += 1) {
            if (i >= max_lines_to_check) break null;
            if (std.mem.indexOfNone(u8, line, line_whitespace)) |index| {
                if (index != last_indent) {
                    const shift = @as(isize, @intCast(index)) - @as(isize, @intCast(last_indent));
                    if (last_content[0] != '*' and last_content[0] != '-' and
                        !std.mem.startsWith(u8, last_content, "/*"))
                    {
                        const magnitude = @abs(shift);
                        if (magnitude < max_indent_width) {
                            if (shift > 0) indent_counts[magnitude] += 1 else deindent_counts[magnitude] += 1;
                            if (context.debug == .verbose) {
                                std.log.info("{s}[{d}]: shift {s}{d} prev: \"{s}\"", .{
                                    context.name, context.line_number, if (shift > 0) "+" else "-", magnitude, last_line,
                                });
                                std.log.info("{s}[{d}]: shift {s}{d} curr: \"{s}\"", .{
                                    context.name, context.line_number, if (shift > 0) "+" else "-", magnitude, line,
                                });
                            }
                            if (indent_counts[magnitude] >= shift_count_threshold) {
                                reason = .threshold;
                                break magnitude;
                            }
                        }
                    }
                    last_indent = index;
                }
                last_content = line[index..];
            }
            last_line = line;
        } else null;
        indent.width = threshold_width orelse blk: {
            var best_shift: usize = context.file_type.width;
            var best_count: usize = 0;
            var tie = false;
            for (indent_counts, 0..) |count, shift| {
                if (count == best_count and count > 0) tie = true;
                if (count > best_count) {
                    best_count = count;
                    best_shift = shift;
                    tie = false;
                }
            }
            if (best_count < minimum_detected_shift_count) {
                reason = .insufficient_evidence;
                break :blk context.file_type.width;
            }
            if (tie) {
                var deindent_best: usize = 0;
                var deindent_count: usize = 0;
                for (deindent_counts, 0..) |count, shift| {
                    if (count > deindent_count) {
                        deindent_count = count;
                        deindent_best = shift;
                    }
                }
                if (deindent_count >= minimum_detected_shift_count) {
                    reason = .max_count_tie_breaker;
                    break :blk deindent_best;
                }
                reason = .tie_file_type_default;
                break :blk context.file_type.width;
            }
            reason = .max_count;
            break :blk best_shift;
        };
    }
    if (context.debug != .off) {
        std.log.info("{s}[{d}]: indent width={d} ({t}, indent_counts={any}, deindent_counts={any}, lines={d})", .{
            context.name, context.line_number, indent.width.?, reason, indent_counts, deindent_counts, i,
        });
    }
}

const max_easy_whitespace_len = 64 - max_indent_width;
const tabs_followed_by_spaces: [max_easy_whitespace_len + max_indent_width]u8 =
    @as([max_easy_whitespace_len]u8, @splat('\t')) ++ @as([max_indent_width]u8, @splat(' '));
const spaces: [max_easy_whitespace_len]u8 = @splat(' ');

pub fn getWhitespace(allocator: std.mem.Allocator, char: u8, len: usize) ![]const u8 {
    if (len <= max_easy_whitespace_len) return if (char == ' ') spaces[0..len] else tabs_followed_by_spaces[0..len];
    const whitespace = try allocator.alloc(u8, len);
    @memset(whitespace, char);
    return whitespace;
}

pub fn getMixedWhitespace(allocator: std.mem.Allocator, tabs: usize, space_count: usize) ![]const u8 {
    if (space_count <= max_indent_width and tabs <= max_easy_whitespace_len) {
        return tabs_followed_by_spaces[max_easy_whitespace_len - tabs .. max_easy_whitespace_len + space_count];
    }
    const whitespace = try allocator.alloc(u8, tabs + space_count);
    @memset(whitespace[0..tabs], '\t');
    @memset(whitespace[tabs..], ' ');
    return whitespace;
}

pub fn match(
    allocator: std.mem.Allocator,
    context: Context,
    output: *std.ArrayList(u8),
    bytes: []const u8,
    desired: Indent,
    current_override: Indent,
) !void {
    if (!desired.enabled) return output.appendSlice(allocator, bytes);
    var current = current_override;
    detect(context, &current, bytes);
    const current_width = current.width.?;
    const current_start = current.start_width.?;
    const current_char = current.char.?;
    const desired_width = desired.width.?;
    const desired_start = desired.start_width.?;
    const desired_char = desired.char.?;
    if (current_width == desired_width and current_start == desired_start and current_char == desired_char) {
        return output.appendSlice(allocator, bytes);
    }
    if (context.debug != .off) {
        std.log.info("{s}[{d}]: reindent current=({c},{d},{d}) desired=({c},{d},{d})", .{
            context.name, context.line_number, current_char,  current_width, current_start,
            desired_char, desired_width,       desired_start,
        });
    }

    var desired_tabs: usize = 0;
    var desired_spaces: usize = undefined;
    const desired_whitespace = if (desired_char == ' ') blk: {
        desired_spaces = desired_start;
        break :blk try getWhitespace(allocator, ' ', desired_spaces);
    } else blk: {
        desired_tabs = desired_start / desired_width;
        desired_spaces = desired_start % desired_width;
        break :blk try getMixedWhitespace(allocator, desired_tabs, desired_spaces);
    };
    const simple = current_char == desired_char and
        ((desired_char == ' ' and current_width == desired_width) or
            (desired_char == '\t' and current_start % current_width == 0 and desired_start % desired_width == 0));
    var add: usize = 0;
    var remove: usize = 0;
    var add_bytes: []const u8 = "";
    var add_columns: usize = 0;
    if (simple) {
        const desired_level = if (desired_char == '\t') desired_start / desired_width else desired_start;
        const current_level = if (desired_char == '\t') current_start / current_width else current_start;
        if (desired_level > current_level) {
            add = desired_level - current_level;
            add_bytes = try getWhitespace(allocator, desired_char, add);
            add_columns = getIndentStart(add_bytes, desired_width);
        } else remove = current_level - desired_level;
    }

    var previous_original_indent: ?usize = null;
    var previous_output_indent: ?usize = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |full_line| {
        const has_return = full_line.len > 0 and full_line[full_line.len - 1] == '\r';
        const line = full_line[0 .. full_line.len - @intFromBool(has_return)];
        const line_start = std.mem.indexOfNone(u8, line, line_whitespace) orelse line.len;
        const line_width = std.mem.count(u8, line[0..line_start], "\t") * current_width +
            std.mem.count(u8, line[0..line_start], " ");
        const use_simple = simple and (current_char != ' ' or std.mem.indexOfScalar(u8, line[0..line_start], '\t') == null);
        var output_indent: usize = line_width;
        if (use_simple) {
            if (add > 0) {
                if (line_start > 0 or (line.len > 0 and current_start == 0)) try output.appendSlice(allocator, add_bytes);
                try output.appendSlice(allocator, line);
                output_indent = line_width + add_columns;
            } else {
                const start = @min(remove, line_start);
                try output.appendSlice(allocator, line[start..]);
                output_indent = line_width - getIndentStart(line[0..start], current_width);
            }
        } else {
            var whitespace = desired_whitespace;
            output_indent = desired_start;
            if (line_width > current_start) {
                const over_start = line_width - current_start;
                if (over_start % current_width != 0 and previous_original_indent != null) {
                    const delta = @as(isize, @intCast(line_width)) - @as(isize, @intCast(previous_original_indent.?));
                    output_indent = @intCast(@max(0, @as(isize, @intCast(previous_output_indent.?)) + delta));
                    whitespace = if (desired_char == ' ')
                        try getWhitespace(allocator, ' ', output_indent)
                    else
                        try getMixedWhitespace(allocator, output_indent / desired_width, output_indent % desired_width);
                } else {
                    const levels = over_start / current_width;
                    const remainder = over_start % current_width;
                    output_indent = desired_start + levels * desired_width + remainder;
                    whitespace = if (desired_char == ' ')
                        try getWhitespace(allocator, ' ', output_indent)
                    else
                        try getMixedWhitespace(allocator, desired_tabs + levels, desired_spaces + remainder);
                }
            }
            if (line_start > 0 or (line.len > 0 and current_start == 0)) try output.appendSlice(allocator, whitespace);
            try output.appendSlice(allocator, line[line_start..]);
        }
        if (line_start < line.len) {
            const start_delta = @as(isize, @intCast(desired_start)) - @as(isize, @intCast(current_start));
            const actual_delta = @as(isize, @intCast(output_indent)) - @as(isize, @intCast(line_width));
            if (@abs(actual_delta - start_delta) > desired_width * 2) {
                std.log.warn("{s}[{d}]: suspicious reindent changed line by {d} columns beyond start delta", .{
                    context.name, context.line_number, actual_delta - start_delta,
                });
            }
            previous_original_indent = line_width;
            previous_output_indent = output_indent;
        }
        if (has_return) try output.append(allocator, '\r');
        if (lines.peek() != null) try output.append(allocator, '\n');
    }
}

fn runMatch(bytes: []const u8, desired: Indent, current: Indent) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    try match(std.testing.allocator, .{ .file_type = .{ .width = 4, .char = ' ' } }, &output, bytes, desired, current);
    return output.toOwnedSlice(std.testing.allocator);
}

test "character, start, and width detection" {
    var indent: Indent = .{};
    detect(.{ .file_type = .{ .width = 4, .char = ' ' } }, &indent, "root\n    one\n        two\n    three\n        four\n    five\n        six\n");
    try std.testing.expectEqual(' ', indent.char.?);
    try std.testing.expectEqual(0, indent.start_width.?);
    try std.testing.expectEqual(4, indent.width.?);

    var tabs: Indent = .{};
    detect(.{ .file_type = .{ .width = 8, .char = '\t' } }, &tabs, "root\n\tone\n\t\ttwo\n\tthree\n");
    try std.testing.expectEqual('\t', tabs.char.?);
    try std.testing.expectEqual(8, tabs.width.?);
    try std.testing.expectEqual(0, tabs.start_width.?);
    try std.testing.expectEqual(10, getIndentStart("\t  ", 8));
}

test "one wrapped argument cannot override file type width" {
    var indent: Indent = .{};
    detect(.{ .file_type = .{ .width = 4, .char = ' ' } }, &indent, "TOKEN(a)\nTOKEN(b)\nTYPE_TRAIT_1(long_name,\n             Continuation)\nTOKEN(c)\n");
    try std.testing.expectEqual(4, indent.width.?);
}

test "width detection requires repeated evidence and ignores comment transitions" {
    var repeated: Indent = .{};
    detect(.{ .file_type = .{ .width = 2, .char = ' ' } }, &repeated, "root\n    a\nroot\n    b\nroot\n    c\n");
    try std.testing.expectEqual(4, repeated.width.?);

    var comments: Indent = .{};
    detect(.{ .file_type = .{ .width = 2, .char = ' ' } }, &comments, "/* comment\n             aligned\n * bullet\n           aligned\n - item\n         aligned\nroot\n");
    try std.testing.expectEqual(2, comments.width.?);
}

test "deleting unrelated flat lines does not change detected width" {
    const before =
        "TOKEN(a)\nTOKEN(b)\nTOKEN(c)\nTYPE_TRAIT(long_name,\n             Continuation)\nTOKEN(d)\n";
    const after = "TOKEN(a)\nTYPE_TRAIT(long_name,\n             Continuation)\nTOKEN(d)\n";
    var before_indent: Indent = .{};
    var after_indent: Indent = .{};
    const context: Context = .{ .file_type = .{ .width = 4, .char = ' ' } };
    detect(context, &before_indent, before);
    detect(context, &after_indent, after);
    try std.testing.expectEqual(before_indent.width, after_indent.width);
    try std.testing.expectEqual(@as(?usize, 4), before_indent.width);
}

test "blank files and character majority use stable fallbacks" {
    var blank: Indent = .{};
    detect(.{ .file_type = .{ .width = 3, .char = '\t' } }, &blank, " \t\n\n   \n");
    try std.testing.expectEqual(0, blank.start_width.?);
    try std.testing.expectEqual('\t', blank.char.?);
    try std.testing.expectEqual(3, blank.width.?);

    var majority: Indent = .{};
    detect(.{ .file_type = .{ .width = 4, .char = '\t' } }, &majority, " space\n space\n space\n space\n\ttab\n");
    try std.testing.expectEqual(' ', majority.char.?);
}

test "match identity and simple prefix" {
    const identity = "  one\n    two\n\n";
    const same = try runMatch(identity, .{ .width = 2, .char = ' ', .start_width = 2 }, .{ .width = 2, .char = ' ', .start_width = 2 });
    defer std.testing.allocator.free(same);
    try std.testing.expectEqualStrings(identity, same);
    const shifted = try runMatch("one\n  two\n", .{ .width = 2, .char = ' ', .start_width = 2 }, .{ .width = 2, .char = ' ', .start_width = 0 });
    defer std.testing.allocator.free(shifted);
    try std.testing.expectEqualStrings("  one\n    two\n", shifted);
}

test "complex width conversion preserves continuation alignment" {
    const source =
        "  call(\n" ++
        "    UNSAFE_BUFFERS(\n" ++
        "                           static_cast<int>(value)));\n" ++
        "      nested;\n";
    const converted = try runMatch(source, .{ .width = 4, .char = ' ', .start_width = 4 }, .{ .width = 2, .char = ' ', .start_width = 2 });
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings(
        "    call(\n" ++
            "        UNSAFE_BUFFERS(\n" ++
            "                               static_cast<int>(value)));\n" ++
            "            nested;\n",
        converted,
    );
}

test "complex width conversion rescales exact nesting levels" {
    const converted = try runMatch("  one\n    two\n      three\nzero\n", .{ .width = 4, .char = ' ', .start_width = 4 }, .{ .width = 2, .char = ' ', .start_width = 2 });
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("    one\n        two\n            three\nzero\n", converted);
}

test "spaces and tabs convert with remainders" {
    const converted = try runMatch("  one\n     aligned\n", .{ .width = 4, .char = '\t', .start_width = 4 }, .{ .width = 2, .char = ' ', .start_width = 2 });
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("\tone\n\t   aligned\n", converted);
}

test "char threshold beats later majority" {
    var indent: Indent = .{};
    detect(.{ .file_type = .{ .width = 4, .char = ' ' } }, &indent, ("  a\n" ** 10) ++ ("\tb\n" ** 20));
    try std.testing.expectEqual(' ', indent.char.?);
}

test "width threshold wins over file type default" {
    var indent: Indent = .{};
    detect(.{ .file_type = .{ .width = 4, .char = ' ' } }, &indent, "r\n   a\n" ** 6);
    try std.testing.expectEqual(3, indent.width.?);
}

test "width tie uses deindents only with repeated evidence" {
    var strong: Indent = .{};
    detect(
        .{ .file_type = .{ .width = 8, .char = ' ' } },
        &strong,
        "a\n  b\n      c\n  d\n    e\n  f\n      g\n  h\n    i\n  j\n      k\n  l\n",
    );
    try std.testing.expectEqual(4, strong.width.?);

    var weak: Indent = .{};
    detect(.{ .file_type = .{ .width = 8, .char = ' ' } }, &weak, "a\n  b\n      c\n" ** 3);
    try std.testing.expectEqual(8, weak.width.?);
}

test "detection stops at max_lines_to_check" {
    var indent: Indent = .{};
    detect(.{ .file_type = .{ .width = 4, .char = ' ' } }, &indent, ("x\n" ** max_lines_to_check) ++ ("r\n   a\n" ** 6));
    try std.testing.expectEqual(' ', indent.char.?);
    try std.testing.expectEqual(4, indent.width.?);
}

test "simple tab add and remove" {
    const added = try runMatch("one\n\ttwo\n", .{ .width = 4, .char = '\t', .start_width = 8 }, .{ .width = 4, .char = '\t', .start_width = 0 });
    defer std.testing.allocator.free(added);
    try std.testing.expectEqualStrings("\t\tone\n\t\t\ttwo\n", added);

    const removed = try runMatch("\t\tone\n\t\t\ttwo\n", .{ .width = 4, .char = '\t', .start_width = 0 }, .{ .width = 4, .char = '\t', .start_width = 8 });
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("one\n\ttwo\n", removed);
}

test "carriage returns survive reindenting" {
    const converted = try runMatch("one\r\n\r\n  two\r\n", .{ .width = 4, .char = ' ', .start_width = 2 }, .{ .width = 2, .char = ' ', .start_width = 0 });
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("  one\r\n\r\n      two\r\n", converted);

    const shifted = try runMatch("one\r\n\r\n", .{ .width = 2, .char = ' ', .start_width = 2 }, .{ .width = 2, .char = ' ', .start_width = 0 });
    defer std.testing.allocator.free(shifted);
    try std.testing.expectEqualStrings("  one\r\n\r\n", shifted);
}

test "whitespace-only lines keep adjusted whitespace" {
    const converted = try runMatch("  one\n   \n  two\n", .{ .width = 4, .char = ' ', .start_width = 4 }, .{ .width = 2, .char = ' ', .start_width = 2 });
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("    one\n     \n    two\n", converted);

    const removed = try runMatch("  one\n    \n", .{ .width = 2, .char = ' ', .start_width = 0 }, .{ .width = 2, .char = ' ', .start_width = 2 });
    defer std.testing.allocator.free(removed);
    try std.testing.expectEqualStrings("one\n  \n", removed);
}
