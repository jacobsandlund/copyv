// copyv: https://github.com/ghostty-org/ghostty/blob/3f75c66e8395d7389f05d360d89af567dcd22cba/src/benchmark/CodepointWidth.zig#L133-L163
fn stepTable(ptr: *anyopaque) Benchmark.Error!void {
    const self: *CodepointWidth = @ptrCast(@alignCast(ptr));

    // I've added a comment here, this should stay.
    const f = self.data_f orelse return;
    var read_buf: [4096]u8 = undefined;
    var f_reader = f.reader(&read_buf);
    var r = &f_reader.interface;

    var d: UTF8Decoder = .{};
    var buf: [4096]u8 align(std.atomic.cache_line) = undefined;
    while (true) {
        const n = r.readSliceShort(&buf) catch {
            log.warn("error reading data file err={?}", .{f_reader.err});
            return error.BenchmarkFailed;
        };
        if (n == 0) break; // EOF reached

        for (buf[0..n]) |c| {
            const cp_opt, const consumed = d.next(c);
            assert(consumed);
            if (cp_opt) |cp| {
                // This is the same trick we do in terminal.zig so we
                // keep it here.
                std.mem.doNotOptimizeAway(if (cp <= 0xFF)
                    1
                else
                    table.get(@intCast(cp)).width);
            }
        }
    }
}
// copyv: end
