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

fn assertFileHashEqual(allocator: std.mem.Allocator, io: std.Io, expected_path: []const u8, actual_path: []const u8) !void {
    const expected_hash = try hashFileAtPath(allocator, io, expected_path);
    const actual_hash = try hashFileAtPath(allocator, io, actual_path);
    try std.testing.expectEqualSlices(u8, &expected_hash, &actual_hash);
}

test "stress full extraction baseline sample" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/stress_out", .{tmp.sub_path});
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var ui = ui_mod.Ui.init(&out_discard.writer, &err_discard.writer, .never, false);

    const start = std.Io.Timestamp.now(io, .real).toNanoseconds();
    var p = try payload.Payload.open(allocator, io, "testdata/payload.bin");
    defer p.deinit();
    try p.init();
    try p.extractAll(out_dir, 4, &ui);
    const elapsed_ns = std.Io.Timestamp.now(io, .real).toNanoseconds() - start;
    try std.testing.expect(elapsed_ns > 0);

    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);
    const system_out = try std.fmt.allocPrint(allocator, "{s}/system.img", .{out_dir});
    defer allocator.free(system_out);
    const vendor_out = try std.fmt.allocPrint(allocator, "{s}/vendor.img", .{out_dir});
    defer allocator.free(vendor_out);

    try assertFileHashEqual(allocator, io, "testdata/reference-extracted/boot.img", boot_out);
    try assertFileHashEqual(allocator, io, "testdata/reference-extracted/system.img", system_out);
    try assertFileHashEqual(allocator, io, "testdata/reference-extracted/vendor.img", vendor_out);
}
