const std = @import("std");
const app = @import("zpayload");
const build_options = @import("build_options");

const default_bench_payload = app.fixtures.sample_payload_path;
const startup_partitions = &[_][]const u8{ "boot", "vbmeta", "vendor_boot" };
const system_partitions = &[_][]const u8{ "system", "vendor", "product", "system_ext" };
const concurrencies = [_]usize{ 1, 2, 4, 8 };

fn benchOutputDir(gpa: std.mem.Allocator, io: std.Io, scenario: []const u8, c: usize) ![]u8 {
    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    return std.fmt.allocPrint(gpa, "{s}/bench_pressure_{s}_c{d}_{d}", .{ build_options.local_cache_dir, scenario, c, nonce });
}

fn mibPerSec(bytes: u64, elapsed_ns: i128) u64 {
    if (elapsed_ns <= 0) return 0;
    const elapsed_ms = @max(@as(i128, 1), @divTrunc(elapsed_ns, std.time.ns_per_ms));
    const bytes_per_sec = (@as(u128, bytes) * 1000) / @as(u128, @intCast(elapsed_ms));
    return @intCast(bytes_per_sec / (1024 * 1024));
}

fn kibPerSec(bytes: u64, elapsed_ns: i128) u64 {
    if (elapsed_ns <= 0) return 0;
    const elapsed_ms = @max(@as(i128, 1), @divTrunc(elapsed_ns, std.time.ns_per_ms));
    const bytes_per_sec = (@as(u128, bytes) * 1000) / @as(u128, @intCast(elapsed_ms));
    return @intCast(bytes_per_sec / 1024);
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

fn runScenario(
    gpa: std.mem.Allocator,
    io: std.Io,
    out: *std.Io.Writer,
    payload_path: []const u8,
    scenario_name: []const u8,
    partitions: []const []const u8,
    c: usize,
) !void {
    const out_dir = try benchOutputDir(gpa, io, scenario_name, c);
    defer gpa.free(out_dir);
    defer std.Io.Dir.cwd().deleteTree(io, out_dir) catch |cleanup_err| {
        std.debug.panic("failed to cleanup benchmark dir '{s}': {}", .{ out_dir, cleanup_err });
    };
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var reporter = app.payload.Reporter.init(&out_discard.writer, &err_discard.writer, false, false);

    const start = std.Io.Timestamp.now(io, .real).toNanoseconds();
    var p = try app.payload.Payload.open(gpa, io, payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, partitions, c, &reporter, app.payload.Sink.noop, null, false);
    const end = std.Io.Timestamp.now(io, .real).toNanoseconds();

    const elapsed_ns = end - start;
    const elapsed_ms: i128 = @divTrunc(elapsed_ns, std.time.ns_per_ms);
    const bytes = try extractedBytes(io, out_dir, partitions);
    try out.print(
        "[BENCH] scenario={s} c={d} elapsed_ms={d} size_kib={d} throughput_kib_s={d} throughput_mib_s={d}\n",
        .{ scenario_name, c, elapsed_ms, bytes / 1024, kibPerSec(bytes, elapsed_ns), mibPerSec(bytes, elapsed_ns) },
    );
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const payload_path = if (args.len >= 2) args[1] else default_bench_payload;

    var out_file = std.Io.File.stdout();
    var out = out_file.writer(io, &.{});
    try out.interface.print("[INFO] pressure bench payload: {s}\n", .{payload_path});
    try out.interface.writeAll("[INFO] scenarios: startup(system boot chain), system(large partitions)\n");
    try out.interface.writeAll("[INFO] concurrencies: 1,2,4,8\n");

    for (concurrencies) |c| {
        try runScenario(gpa, io, &out.interface, payload_path, "startup", startup_partitions, c);
    }
    for (concurrencies) |c| {
        try runScenario(gpa, io, &out.interface, payload_path, "system", system_partitions, c);
    }

    try out.interface.writeAll("[OK] bench_pressure complete\n");
}
