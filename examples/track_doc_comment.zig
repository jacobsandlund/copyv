//! copyv: https://github.com/jacobsandlund/copyv/blob/6d3072f24276501de77702075d9227cb6656eda3/examples/track_merge.zig#L1-L35 begin
// copyv: https://github.com/ghostty-org/ghostty/blob/26e9b0a0f3b07149c7fd7474519eba6b21f8c5fd/src/benchmark/CodepointWidth.zig#L134-L165 begin
fn stepTable(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));

    // I've added a comment here, this should stay.
    // ... and I've added another comment here.
    const f = self.data_f orelse return;
    var r = std.io.bufferedReader(f.reader());
    var d: UTF8Decoder = .{};
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = r.read(&buf) catch |err| {
            log.warn("error reading data file err={}", .{err});
            return error.BenchmarkFailed;
        };
        if (n == 0) {
            break; // EOF reached
        }

        for (buf[0..n]) |c| {
            const cp_opt, const consumed = d.next(c);
            assert(consumed);
            if (cp_opt) |cp| {
                // This is the same trick we do in terminal.zig so we
                // keep it here.
                const width = if (cp <= 0xFF)
                    1
                else
                    table.get(@intCast(cp)).width;

                // Write the width to the buffer to avoid it being compiled
                // away
                buf[0] = @intCast(width);
            }
        }
    }
}
// copyv: end
// copyv: end
