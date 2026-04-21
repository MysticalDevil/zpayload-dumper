const std = @import("std");
const app = @import("zpayload");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const payload_path = if (args.len >= 2) args[1] else app.fixtures.sample_payload_path;
    const baseline_dir = if (args.len >= 3) args[2] else app.fixtures.sample_extracted_dir;

    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const output_dir = try std.fmt.allocPrint(gpa, "{s}/e2e_out_{d}", .{ build_options.local_cache_dir, nonce });
    defer gpa.free(output_dir);
    defer std.Io.Dir.cwd().deleteTree(io, output_dir) catch |cleanup_err| {
        std.debug.panic("failed to cleanup output dir '{s}': {}", .{ output_dir, cleanup_err });
    };
    try std.Io.Dir.cwd().createDirPath(io, output_dir);

    var out_file = std.Io.File.stdout();
    var out = out_file.writer(io, &.{});
    try out.interface.print("[INFO] payload: {s}\n", .{payload_path});
    try out.interface.print("[INFO] baseline: {s}\n", .{baseline_dir});
    try out.interface.print("[INFO] output: {s}\n", .{output_dir});

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var reporter = app.payload.Reporter.init(&out_discard.writer, &err_discard.writer, false, false);

    var p = try app.payload.Payload.open(gpa, io, payload_path);
    defer p.deinit();
    try p.init();
    try p.extractAll(output_dir, 4, &reporter, app.payload.Sink.noop, null, false);

    try app.fs_hash.compareDirs(gpa, io, baseline_dir, output_dir);
    try out.interface.writeAll("[OK] e2e check passed\n");
}
