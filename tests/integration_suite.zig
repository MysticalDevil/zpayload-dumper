const std = @import("std");
const app = @import("zpayload");
const build_options = @import("build_options");

const selected_triplet = &app.fixtures.selected_triplet;

fn testOutputPath(allocator: std.mem.Allocator, tmp_sub_path: []const u8, suffix: []const u8) ![]u8 {
    return app.platform.joinOwned(allocator, &.{ build_options.local_cache_dir, "tmp", tmp_sub_path, suffix });
}

fn createTarFixture(
    allocator: std.mem.Allocator,
    io: std.Io,
    tmp_sub_path: []const u8,
    source_payload_path: []const u8,
) ![]u8 {
    const tar_path = try testOutputPath(allocator, tmp_sub_path, "sample_payload.tar");
    errdefer allocator.free(tar_path);

    var source_file = try std.Io.Dir.cwd().openFile(io, source_payload_path, .{ .mode = .read_only });
    defer source_file.close(io);

    var tar_file = try std.Io.Dir.cwd().createFile(io, tar_path, .{ .truncate = true });
    defer tar_file.close(io);

    var source_buf: [4096]u8 = undefined;
    var tar_buf: [4096]u8 = undefined;
    var tar_writer = tar_file.writer(io, &tar_buf);
    var writer: std.tar.Writer = .{ .underlying_writer = &tar_writer.interface };
    var file_reader = std.Io.File.Reader.init(source_file, io, &source_buf);

    try writer.writeFile("payload.bin", &file_reader, 0);
    try tar_writer.interface.flush();

    return tar_path;
}

fn generatedFixturePath(allocator: std.mem.Allocator, name: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "tests/data/generated/{s}/{s}", .{ name, suffix });
}

const TestReporter = struct {
    out_buf: [64]u8 = undefined,
    err_buf: [64]u8 = undefined,
    out_discard: std.Io.Writer.Discarding = undefined,
    err_discard: std.Io.Writer.Discarding = undefined,
    reporter: app.payload.Reporter = undefined,

    fn init() TestReporter {
        var result = TestReporter{};
        result.out_discard = std.Io.Writer.Discarding.init(&result.out_buf);
        result.err_discard = std.Io.Writer.Discarding.init(&result.err_buf);
        result.reporter = app.payload.Reporter.init(&result.out_discard.writer, &result.err_discard.writer, false, false);
        return result;
    }
};

test "integration selected partitions match go baseline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], "out");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var reporter_holder = TestReporter.init();
    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, selected_triplet, 2, &reporter_holder.reporter, app.payload.Sink.noop, null, false);

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

    const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], "only_vendor_boot");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var reporter_holder = TestReporter.init();

    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{"vendor_boot"}, 2, &reporter_holder.reporter, app.payload.Sink.noop, null, false);

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

test "payload opened into predeclared variable keeps context initialized" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var p: app.payload.Payload = undefined;
    p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();

    try p.init();
    try std.testing.expectEqual(@as(usize, 24), try p.partitionCount());
}

test "extract selected unknown partition produces no files" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], "unknown_partition");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var reporter_holder = TestReporter.init();

    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{"not_exist_partition"}, 2, &reporter_holder.reporter, app.payload.Sink.noop, null, false);

    try std.testing.expectEqual(@as(usize, 0), try app.fs_hash.countFilesInDir(allocator, io, out_dir));
}

test "invalid magic payload returns InvalidMagic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const bad_path = try testOutputPath(allocator, tmp.sub_path[0..], "bad_payload.bin");
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
    var reporter_holder = TestReporter.init();

    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try std.testing.expectError(error.InvalidConcurrency, p.extractAll(build_options.local_cache_dir, 0, &reporter_holder.reporter, app.payload.Sink.noop, null, false));
}

test "zip input extraction path matches sample baseline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const zip_path = app.fixtures.sample_ota_zip_path;
    if (!app.fs_hash.fileExists(io, zip_path)) return error.SkipZigTest;

    const extracted = try app.input.payload_zip.extractPayloadBinFromZip(allocator, io, zip_path);
    defer {
        app.input.payload_zip.cleanupExtractedPayloadTempDir(io, extracted.temp_dir) catch |cleanup_err| {
            std.debug.panic("failed to cleanup temp dir '{s}': {}", .{ extracted.temp_dir, cleanup_err });
        };
        allocator.free(extracted.temp_dir);
        allocator.free(extracted.payload_path);
    }

    try std.testing.expect(app.fs_hash.fileExists(io, extracted.payload_path));

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], "zip_out");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var reporter_holder = TestReporter.init();

    var p = try app.payload.Payload.open(allocator, io, extracted.payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, selected_triplet, 2, &reporter_holder.reporter, app.payload.Sink.noop, null, false);

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

test "zip temp extraction cleanup removes extracted temp dir" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const zip_path = app.fixtures.sample_ota_zip_path;
    if (!app.fs_hash.fileExists(io, zip_path)) return error.SkipZigTest;

    const extracted = try app.input.payload_zip.extractPayloadBinFromZip(allocator, io, zip_path);
    defer allocator.free(extracted.temp_dir);
    defer allocator.free(extracted.payload_path);

    try std.testing.expect(app.fs_hash.fileExists(io, extracted.payload_path));
    try app.input.payload_zip.cleanupExtractedPayloadTempDir(io, extracted.temp_dir);
    try std.testing.expect(!app.fs_hash.fileExists(io, extracted.payload_path));
}

test "tar input extraction path matches sample baseline" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    if (!app.fs_hash.fileExists(io, app.fixtures.sample_payload_path)) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const tar_path = try createTarFixture(allocator, io, tmp.sub_path[0..], app.fixtures.sample_payload_path);
    defer allocator.free(tar_path);

    const extracted = try app.input.payload_tar.extractPayloadBinFromTar(allocator, io, tar_path);
    defer {
        app.input.payload_tar.cleanupExtractedPayloadTempDir(io, extracted.temp_dir) catch |cleanup_err| {
            std.debug.panic("failed to cleanup tar temp dir '{s}': {}", .{ extracted.temp_dir, cleanup_err });
        };
        allocator.free(extracted.temp_dir);
        allocator.free(extracted.payload_path);
    }

    try std.testing.expect(app.fs_hash.fileExists(io, extracted.payload_path));

    const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], "tar_out");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var reporter_holder = TestReporter.init();

    var p = try app.payload.Payload.open(allocator, io, extracted.payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, selected_triplet, 2, &reporter_holder.reporter, app.payload.Sink.noop, null, false);

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

test "bench512 modem partition extracts successfully" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const payload_path = try generatedFixturePath(allocator, "bench512", "payload.bin");
    defer allocator.free(payload_path);
    const modem_expected = try generatedFixturePath(allocator, "bench512", "extracted/modem.img");
    defer allocator.free(modem_expected);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], "bench512_modem");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var reporter_holder = TestReporter.init();

    var p = try app.payload.Payload.open(allocator, io, payload_path);
    defer p.deinit();
    try p.init();
    try p.extractSelected(out_dir, &.{"modem"}, 4, &reporter_holder.reporter, app.payload.Sink.noop, null, false);

    const modem_out = try std.fmt.allocPrint(allocator, "{s}/modem.img", .{out_dir});
    defer allocator.free(modem_out);
    try app.fs_hash.assertFileHashEqual(allocator, io, modem_expected, modem_out);
}
