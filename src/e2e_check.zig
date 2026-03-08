const std = @import("std");
const payload = @import("payload.zig");
const ui_mod = @import("cli_ui.zig");

fn hashFileAtPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const buf = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(buf);

    var off: u64 = 0;
    while (off < stat.size) {
        const n: usize = @intCast(@min(stat.size - off, buf.len));
        _ = try file.readPositionalAll(io, buf[0..n], off);
        hasher.update(buf[0..n]);
        off += n;
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

fn compareDirs(allocator: std.mem.Allocator, io: std.Io, baseline_dir: []const u8, output_dir: []const u8) !void {
    var baseline_open = try std.Io.Dir.cwd().openDir(io, baseline_dir, .{ .iterate = true });
    defer baseline_open.close(io);

    var walker = try std.Io.Dir.walk(baseline_open, allocator);
    defer walker.deinit();

    var baseline_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        baseline_count += 1;

        const expected_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ baseline_dir, entry.path });
        defer allocator.free(expected_path);
        const actual_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, entry.path });
        defer allocator.free(actual_path);

        const expected_stat = try std.Io.Dir.cwd().statFile(io, expected_path, .{});
        const actual_stat = try std.Io.Dir.cwd().statFile(io, actual_path, .{});
        if (expected_stat.size != actual_stat.size) return error.SizeMismatch;

        const expected_hash = try hashFileAtPath(allocator, io, expected_path);
        const actual_hash = try hashFileAtPath(allocator, io, actual_path);
        if (!std.mem.eql(u8, &expected_hash, &actual_hash)) return error.HashMismatch;
    }

    var output_open = try std.Io.Dir.cwd().openDir(io, output_dir, .{ .iterate = true });
    defer output_open.close(io);
    var out_walker = try std.Io.Dir.walk(output_open, allocator);
    defer out_walker.deinit();

    var output_count: usize = 0;
    while (try out_walker.next(io)) |entry| {
        if (entry.kind == .file) output_count += 1;
    }
    if (baseline_count != output_count) return error.FileCountMismatch;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const payload_path = if (args.len >= 2) args[1] else "tests/data/generated/smoke1/payload.bin";
    const baseline_dir = if (args.len >= 3) args[2] else "tests/data/generated/smoke1/extracted";

    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const output_dir = try std.fmt.allocPrint(gpa, ".zig-cache/e2e_out_{d}", .{nonce});
    defer gpa.free(output_dir);
    defer std.Io.Dir.cwd().deleteTree(io, output_dir) catch {};
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
    var ui = ui_mod.Ui.init(&out_discard.writer, &err_discard.writer, .never, false);

    var p = try payload.Payload.open(gpa, io, payload_path);
    defer p.deinit();
    try p.init();
    try p.extractAll(output_dir, 4, &ui);

    try compareDirs(gpa, io, baseline_dir, output_dir);
    try out.interface.writeAll("[OK] e2e check passed\n");
}
