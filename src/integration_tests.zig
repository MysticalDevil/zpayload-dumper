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

test "integration selected partitions match go baseline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/out", .{tmp.sub_path});
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var ui = ui_mod.Ui.init(&out_discard.writer, &err_discard.writer, .never, false);
    var p = try payload.Payload.open(allocator, io, "testdata/payload.bin");
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{ "boot", "vbmeta", "vendor_boot" }, 2, &ui);

    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);
    const vbmeta_out = try std.fmt.allocPrint(allocator, "{s}/vbmeta.img", .{out_dir});
    defer allocator.free(vbmeta_out);
    const vendor_boot_out = try std.fmt.allocPrint(allocator, "{s}/vendor_boot.img", .{out_dir});
    defer allocator.free(vendor_boot_out);

    try assertFileHashEqual(allocator, io, "testdata/payload-dumper-go-extracted/boot.img", boot_out);
    try assertFileHashEqual(allocator, io, "testdata/payload-dumper-go-extracted/vbmeta.img", vbmeta_out);
    try assertFileHashEqual(allocator, io, "testdata/payload-dumper-go-extracted/vendor_boot.img", vendor_boot_out);
}

test "invalid magic payload returns InvalidMagic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bad_path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/bad_payload.bin", .{tmp.sub_path});
    defer allocator.free(bad_path);
    {
        var f = try std.Io.Dir.cwd().createFile(io, bad_path, .{ .truncate = true });
        defer f.close(io);
        var wbuf: [32]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.writeAll("BAD!");
        try w.flush();
    }

    var p = try payload.Payload.open(allocator, io, bad_path);
    defer p.deinit();
    try std.testing.expectError(error.InvalidMagic, p.init());
}

test "invalid concurrency returns InvalidConcurrency" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var ui = ui_mod.Ui.init(&out_discard.writer, &err_discard.writer, .never, false);

    var p = try payload.Payload.open(allocator, io, "testdata/payload.bin");
    defer p.deinit();
    try p.init();
    try std.testing.expectError(error.InvalidConcurrency, p.extractAll(".zig-cache", 0, &ui));
}
