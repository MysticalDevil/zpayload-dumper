const std = @import("std");
const app = @import("zpayload");

const default_bench_payload = app.fixtures.sample_payload_path;
const bench_partitions = &app.fixtures.selected_triplet;

fn defaultOutputDir(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    return std.fmt.allocPrint(gpa, ".zig-cache/bench_smoke_{d}", .{nonce});
}

fn mibPerSec(bytes: u64, elapsed_ns: i128) u64 {
    if (elapsed_ns <= 0) return 0;
    const elapsed_ms = @max(@as(i128, 1), @divTrunc(elapsed_ns, std.time.ns_per_ms));
    const bytes_per_sec = (@as(u128, bytes) * 1000) / @as(u128, @intCast(elapsed_ms));
    return @intCast(bytes_per_sec / (1024 * 1024));
}

fn extractedBytes(io: std.Io, out_dir: []const u8, names: []const []const u8) !u64 {
    var total: u64 = 0;
    for (names) |name| {
        const path = try std.fmt.allocPrint(std.heap.page_allocator, "{s}/{s}.img", .{ out_dir, name });
        defer std.heap.page_allocator.free(path);
        const st = try std.Io.Dir.cwd().statFile(io, path, .{});
        total += st.size;
    }
    return total;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const payload_path = if (args.len >= 2) args[1] else default_bench_payload;
    const partitions: []const []const u8 = bench_partitions;
    const concurrencies = [_]usize{ 1, 4 };

    var out_file = std.Io.File.stdout();
    var out = out_file.writer(io, &.{});
    try out.interface.print("[INFO] bench payload: {s}\n", .{payload_path});
    try out.interface.print("[INFO] partitions: {s},{s},{s}\n", .{
        app.fixtures.selected_triplet[0],
        app.fixtures.selected_triplet[1],
        app.fixtures.selected_triplet[2],
    });
    try out.interface.print("[INFO] runs: concurrency=1,4\n", .{});

    for (concurrencies) |c| {
        const out_dir = try defaultOutputDir(gpa, io);
        defer gpa.free(out_dir);
        defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, out_dir);

        var out_buf: [64]u8 = undefined;
        var err_buf: [64]u8 = undefined;
        var out_discard = std.Io.Writer.Discarding.init(&out_buf);
        var err_discard = std.Io.Writer.Discarding.init(&err_buf);
        var ui = app.payload.Ui.init(&out_discard.writer, &err_discard.writer, app.payload.ColorMode.never, false);

        const start = std.Io.Timestamp.now(io, .real).toNanoseconds();
        var p = try app.payload.Payload.open(gpa, io, payload_path);
        defer p.deinit();
        try p.init();
        try p.extractSelected(out_dir, partitions, c, &ui);
        const end = std.Io.Timestamp.now(io, .real).toNanoseconds();

        const elapsed_ns = end - start;
        const elapsed_ms: i128 = @divTrunc(elapsed_ns, std.time.ns_per_ms);
        const bytes = try extractedBytes(io, out_dir, partitions);
        try out.interface.print(
            "[BENCH] c={d} elapsed_ms={d} size_mib={d} throughput_mib_s={d}\n",
            .{ c, elapsed_ms, bytes / (1024 * 1024), mibPerSec(bytes, elapsed_ns) },
        );
    }

    try out.interface.writeAll("[OK] bench-smoke complete\n");
}
