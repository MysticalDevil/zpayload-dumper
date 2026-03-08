const std = @import("std");
const payload = @import("payload.zig");
const ui_mod = @import("cli_ui.zig");
const zip_input = @import("zip_input.zig");

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

fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

fn countFilesInDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try std.Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) n += 1;
    }
    return n;
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
    var p = try payload.Payload.open(allocator, io, "tests/data/generated/smoke1/payload.bin");
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{ "boot", "vbmeta", "vendor_boot" }, 2, &ui);

    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);
    const vbmeta_out = try std.fmt.allocPrint(allocator, "{s}/vbmeta.img", .{out_dir});
    defer allocator.free(vbmeta_out);
    const vendor_boot_out = try std.fmt.allocPrint(allocator, "{s}/vendor_boot.img", .{out_dir});
    defer allocator.free(vendor_boot_out);

    try assertFileHashEqual(allocator, io, "tests/data/generated/smoke1/extracted/boot.img", boot_out);
    try assertFileHashEqual(allocator, io, "tests/data/generated/smoke1/extracted/vbmeta.img", vbmeta_out);
    try assertFileHashEqual(allocator, io, "tests/data/generated/smoke1/extracted/vendor_boot.img", vendor_boot_out);
}

test "extract selected writes only requested partition" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/only_vendor_boot", .{tmp.sub_path});
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var ui = ui_mod.Ui.init(&out_discard.writer, &err_discard.writer, .never, false);

    var p = try payload.Payload.open(allocator, io, "tests/data/generated/smoke1/payload.bin");
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{"vendor_boot"}, 2, &ui);

    const vendor_boot_out = try std.fmt.allocPrint(allocator, "{s}/vendor_boot.img", .{out_dir});
    defer allocator.free(vendor_boot_out);
    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);

    try std.testing.expect(fileExists(io, vendor_boot_out));
    try std.testing.expect(!fileExists(io, boot_out));
    try assertFileHashEqual(allocator, io, "tests/data/generated/smoke1/extracted/vendor_boot.img", vendor_boot_out);
}

test "sample payload partition count is stable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var p = try payload.Payload.open(allocator, io, "tests/data/generated/smoke1/payload.bin");
    defer p.deinit();
    try p.init();
    try std.testing.expectEqual(@as(usize, 5), try p.partitionCount());
}

test "extract selected unknown partition produces no files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/unknown_partition", .{tmp.sub_path});
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var ui = ui_mod.Ui.init(&out_discard.writer, &err_discard.writer, .never, false);

    var p = try payload.Payload.open(allocator, io, "tests/data/generated/smoke1/payload.bin");
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{"not_exist_partition"}, 2, &ui);

    try std.testing.expectEqual(@as(usize, 0), try countFilesInDir(allocator, io, out_dir));
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

    var p = try payload.Payload.open(allocator, io, "tests/data/generated/smoke1/payload.bin");
    defer p.deinit();
    try p.init();
    try std.testing.expectError(error.InvalidConcurrency, p.extractAll(".zig-cache", 0, &ui));
}

test "zip input extraction path matches sample baseline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const zip_path = "tests/data/generated/smoke1/ota_update.zip";
    if (!fileExists(io, zip_path)) return error.SkipZigTest;

    const tmp_base = "/tmp";
    var extracted = try zip_input.extractPayloadBinFromZip(allocator, io, tmp_base, zip_path);
    defer {
        std.Io.Dir.cwd().deleteTree(io, extracted.temp_dir) catch {};
        allocator.free(extracted.temp_dir);
        allocator.free(extracted.payload_path);
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_dir = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}/zip_out", .{tmp.sub_path});
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var ui = ui_mod.Ui.init(&out_discard.writer, &err_discard.writer, .never, false);

    var p = try payload.Payload.open(allocator, io, extracted.payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{ "boot", "vbmeta", "vendor_boot" }, 2, &ui);

    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);
    const vbmeta_out = try std.fmt.allocPrint(allocator, "{s}/vbmeta.img", .{out_dir});
    defer allocator.free(vbmeta_out);
    const vendor_boot_out = try std.fmt.allocPrint(allocator, "{s}/vendor_boot.img", .{out_dir});
    defer allocator.free(vendor_boot_out);

    try assertFileHashEqual(allocator, io, "tests/data/generated/smoke1/extracted/boot.img", boot_out);
    try assertFileHashEqual(allocator, io, "tests/data/generated/smoke1/extracted/vbmeta.img", vbmeta_out);
    try assertFileHashEqual(allocator, io, "tests/data/generated/smoke1/extracted/vendor_boot.img", vendor_boot_out);
}
