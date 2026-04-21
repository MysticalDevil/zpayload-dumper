const std = @import("std");
const app = @import("zpayload");
const build_options = @import("build_options");

const selected_triplet = &app.fixtures.selected_triplet;

fn testOutputPath(allocator: std.mem.Allocator, tmp_sub_path: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/tmp/{s}/{s}", .{ build_options.local_cache_dir, tmp_sub_path, suffix });
}

fn assertKeyBaselines(allocator: std.mem.Allocator, io: std.Io, out_dir: []const u8) !void {
    const boot_out = try std.fmt.allocPrint(allocator, "{s}/boot.img", .{out_dir});
    defer allocator.free(boot_out);
    const product_out = try std.fmt.allocPrint(allocator, "{s}/product.img", .{out_dir});
    defer allocator.free(product_out);
    const system_ext_out = try std.fmt.allocPrint(allocator, "{s}/system_ext.img", .{out_dir});
    defer allocator.free(system_ext_out);

    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_boot_img, boot_out);
    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_product_img, product_out);
    try app.fs_hash.assertFileHashEqual(allocator, io, app.fixtures.sample_system_ext_img, system_ext_out);
}

test "stress full extraction baseline sample" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], "stress_out");
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var out_buf: [64]u8 = undefined;
    var err_buf: [64]u8 = undefined;
    var out_discard = std.Io.Writer.Discarding.init(&out_buf);
    var err_discard = std.Io.Writer.Discarding.init(&err_buf);
    var reporter = app.payload.Reporter.init(&out_discard.writer, &err_discard.writer, false, false);

    const start = std.Io.Timestamp.now(io, .real).toNanoseconds();
    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try p.extractAll(out_dir, 4, &reporter, app.payload.Sink.noop, null, false);
    const elapsed_ns = std.Io.Timestamp.now(io, .real).toNanoseconds() - start;
    try std.testing.expect(elapsed_ns > 0);

    try assertKeyBaselines(allocator, io, out_dir);
}

test "stress selected triplet concurrency matrix is stable" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const rounds = 3;
    const concurrencies = [_]usize{ 1, 2, 4, 8 };

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        for (concurrencies) |c| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const suffix = try std.fmt.allocPrint(allocator, "stress_selected_c{d}", .{c});
            defer allocator.free(suffix);
            const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], suffix);
            defer allocator.free(out_dir);
            try std.Io.Dir.cwd().createDirPath(io, out_dir);

            var out_buf: [64]u8 = undefined;
            var err_buf: [64]u8 = undefined;
            var out_discard = std.Io.Writer.Discarding.init(&out_buf);
            var err_discard = std.Io.Writer.Discarding.init(&err_buf);
            var reporter = app.payload.Reporter.init(&out_discard.writer, &err_discard.writer, false, false);
            var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
            defer p.deinit();
            try p.init();
            try p.extractSelected(out_dir, selected_triplet, c, &reporter, app.payload.Sink.noop, null, false);

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
    }
}

test "stress full extraction repeats keep file count and hashes" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const rounds = 3;

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const suffix = try std.fmt.allocPrint(allocator, "stress_all_round_{d}", .{round});
        defer allocator.free(suffix);
        const out_dir = try testOutputPath(allocator, tmp.sub_path[0..], suffix);
        defer allocator.free(out_dir);
        try std.Io.Dir.cwd().createDirPath(io, out_dir);

        var out_buf: [64]u8 = undefined;
        var err_buf: [64]u8 = undefined;
        var out_discard = std.Io.Writer.Discarding.init(&out_buf);
        var err_discard = std.Io.Writer.Discarding.init(&err_buf);
        var reporter = app.payload.Reporter.init(&out_discard.writer, &err_discard.writer, false, false);
        var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
        defer p.deinit();
        try p.init();
        try p.extractAll(out_dir, 4, &reporter, app.payload.Sink.noop, null, false);

        try std.testing.expectEqual(@as(usize, 24), try app.fs_hash.countFilesInDir(allocator, io, out_dir));
        try assertKeyBaselines(allocator, io, out_dir);
    }
}
