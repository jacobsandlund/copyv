const std = @import("std");

pub const Eol = enum {
    lf,
    crlf,

    pub fn bytes(self: Eol) []const u8 {
        return switch (self) {
            .lf => "\n",
            .crlf => "\r\n",
        };
    }
};

pub fn detect(file_bytes: []const u8) Eol {
    const crlf_count = std.mem.count(u8, file_bytes, "\r\n");
    const lf_count = std.mem.count(u8, file_bytes, "\n") - crlf_count;
    return if (crlf_count > lf_count) .crlf else .lf;
}

pub fn convert(allocator: std.mem.Allocator, input: []const u8, eol: Eol) ![]const u8 {
    const crlf_count = std.mem.count(u8, input, "\r\n");
    switch (eol) {
        .lf => {
            if (crlf_count == 0) return input;
            var output = try std.ArrayList(u8).initCapacity(allocator, input.len - crlf_count);
            for (input, 0..) |byte, i| {
                if (byte == '\r' and i + 1 < input.len and input[i + 1] == '\n') continue;
                output.appendAssumeCapacity(byte);
            }
            return output.items;
        },
        .crlf => {
            const bare_lf_count = std.mem.count(u8, input, "\n") - crlf_count;
            if (bare_lf_count == 0) return input;
            var output = try std.ArrayList(u8).initCapacity(allocator, input.len + bare_lf_count);
            for (input, 0..) |byte, i| {
                if (byte == '\n' and (i == 0 or input[i - 1] != '\r')) {
                    output.appendAssumeCapacity('\r');
                }
                output.appendAssumeCapacity(byte);
            }
            return output.items;
        },
    }
}

// A chunk slice ends just before a '\n'; a trailing '\r' belongs to that line
// terminator, not the chunk.
pub fn canonicalizeChunk(allocator: std.mem.Allocator, chunk: []const u8) ![]const u8 {
    const trimmed = if (chunk.len > 0 and chunk[chunk.len - 1] == '\r')
        chunk[0 .. chunk.len - 1]
    else
        chunk;
    return convert(allocator, trimmed, .lf);
}

test "detect picks the majority line ending" {
    try std.testing.expectEqual(Eol.lf, detect("one\ntwo\nthree\n"));
    try std.testing.expectEqual(Eol.crlf, detect("one\r\ntwo\r\nthree\r\n"));
    try std.testing.expectEqual(Eol.lf, detect("one\r\ntwo\nthree\nfour\n"));
    try std.testing.expectEqual(Eol.crlf, detect("one\r\ntwo\r\nthree\n"));
    try std.testing.expectEqual(Eol.lf, detect(""));
    try std.testing.expectEqual(Eol.lf, detect("no newline"));
}

test "convert to lf strips returns only from crlf pairs" {
    const converted = try convert(std.testing.allocator, "one\r\ntwo\r\nlone\rreturn\r\n", .lf);
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("one\ntwo\nlone\rreturn\n", converted);
}

test "convert to crlf adds returns to bare newlines" {
    const converted = try convert(std.testing.allocator, "one\ntwo\r\nlone\rreturn\n", .crlf);
    defer std.testing.allocator.free(converted);
    try std.testing.expectEqualStrings("one\r\ntwo\r\nlone\rreturn\r\n", converted);
}

test "canonicalizeChunk drops the trailing terminator remnant" {
    const canonical = try canonicalizeChunk(std.testing.allocator, "one\r\ntwo\r");
    defer std.testing.allocator.free(canonical);
    try std.testing.expectEqualStrings("one\ntwo", canonical);

    const empty = try canonicalizeChunk(std.testing.allocator, "\r");
    try std.testing.expectEqualStrings("", empty);
}

test "convert returns the input unchanged when already conforming" {
    const lf_input = "one\ntwo\nlone\rreturn\n";
    const lf_converted = try convert(std.testing.allocator, lf_input, .lf);
    try std.testing.expectEqual(lf_input.ptr, lf_converted.ptr);

    const crlf_input = "one\r\ntwo\r\n";
    const crlf_converted = try convert(std.testing.allocator, crlf_input, .crlf);
    try std.testing.expectEqual(crlf_input.ptr, crlf_converted.ptr);
}
