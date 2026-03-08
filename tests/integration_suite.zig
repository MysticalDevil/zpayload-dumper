const std = @import("std");
const app = @import("zpayload");

const selected_triplet = &app.fixtures.selected_triplet;
const default_tmp_base = "/tmp";

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
    var ui = app.payload.Ui.init(&out_discard.writer, &err_discard.writer, app.payload.ColorMode.never, false);
    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, selected_triplet, 2, &ui);

    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);
    const vbmeta_out = try std.fmt.allocPrint(allocator, "{s}/vbmeta.img", .{out_dir});
    defer allocator.free(vbmeta_out);
    const vendor_boot_out = try std.fmt.allocPrint(allocator, "{s}/vendor_boot.img", .{out_dir});
    defer allocator.free(vendor_boot_out);

    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_boot_img, boot_out);
    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_vbmeta_img, vbmeta_out);
    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_vendor_boot_img, vendor_boot_out);
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
    var ui = app.payload.Ui.init(&out_discard.writer, &err_discard.writer, app.payload.ColorMode.never, false);

    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{"vendor_boot"}, 2, &ui);

    const vendor_boot_out = try std.fmt.allocPrint(allocator, "{s}/vendor_boot.img", .{out_dir});
    defer allocator.free(vendor_boot_out);
    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);

    try std.testing.expect(app.fs_hash.fileExists(io, vendor_boot_out));
    try std.testing.expect(!app.fs_hash.fileExists(io, boot_out));
    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_vendor_boot_img, vendor_boot_out);
}

test "sample payload partition count is stable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try std.testing.expectEqual(@as(usize, 24), try p.partitionCount());
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
    var ui = app.payload.Ui.init(&out_discard.writer, &err_discard.writer, app.payload.ColorMode.never, false);

    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{"not_exist_partition"}, 2, &ui);

    try std.testing.expectEqual(@as(usize, 0), try app.fs_hash.countFilesInDir(allocator, io, out_dir));
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

    var p = try app.payload.Payload.open(allocator, io, bad_path);
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
    var ui = app.payload.Ui.init(&out_discard.writer, &err_discard.writer, app.payload.ColorMode.never, false);

    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try std.testing.expectError(error.InvalidConcurrency, p.extractAll(".zig-cache", 0, &ui));
}

test "zip input extraction path matches sample baseline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const zip_path = app.fixtures.sample_ota_zip_path;
    if (!app.fs_hash.fileExists(io, zip_path)) return error.SkipZigTest;

    const tmp_base = default_tmp_base;
    var extracted = try app.zip_payload.extractPayloadBinFromZip(allocator, io, tmp_base, zip_path);
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
    var ui = app.payload.Ui.init(&out_discard.writer, &err_discard.writer, app.payload.ColorMode.never, false);

    var p = try app.payload.Payload.open(allocator, io, extracted.payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, selected_triplet, 2, &ui);

    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);
    const vbmeta_out = try std.fmt.allocPrint(allocator, "{s}/vbmeta.img", .{out_dir});
    defer allocator.free(vbmeta_out);
    const vendor_boot_out = try std.fmt.allocPrint(allocator, "{s}/vendor_boot.img", .{out_dir});
    defer allocator.free(vendor_boot_out);

    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_boot_img, boot_out);
    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_vbmeta_img, vbmeta_out);
    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_vendor_boot_img, vendor_boot_out);
}
