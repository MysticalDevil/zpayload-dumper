const std = @import("std");
const app = @import("zpayload");

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
    var ui = app.payload.Ui.init(&out_discard.writer, &err_discard.writer, app.payload.ColorMode.never, false);

    const start = std.Io.Timestamp.now(io, .real).toNanoseconds();
    var p = try app.payload.Payload.open(allocator, io, app.fixtures.sample_payload_path);
    defer p.deinit();
    try p.init();
    try p.extractAll(out_dir, 4, &ui);
    const elapsed_ns = std.Io.Timestamp.now(io, .real).toNanoseconds() - start;
    try std.testing.expect(elapsed_ns > 0);

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
