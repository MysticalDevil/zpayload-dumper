const std = @import("std");
const errors = @import("errors.zig");

pub const Error = errors.AppError;

pub const ZipExtractResult = struct {
    temp_dir: []u8,
    payload_path: []u8,
};

pub fn extractPayloadBinFromZip(allocator: std.mem.Allocator, io: std.Io, tmp_base: []const u8, zip_path: []const u8) Error!ZipExtractResult {
    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/zpayload_{d}", .{ tmp_base, nonce });
    std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch return error.IoFailure;

    var zip_file = std.Io.Dir.cwd().openFile(io, zip_path, .{}) catch return error.InvalidZipArchive;
    defer zip_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr = zip_file.reader(io, &reader_buf);
    var iter = std.zip.Iterator.init(&fr) catch return error.InvalidZipArchive;
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    var temp_dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return error.IoFailure;
    defer temp_dir.close(io);

    while (iter.next() catch return error.InvalidZipArchive) |entry| {
        fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch return error.InvalidZipArchive;
        const name = filename_buf[0..entry.filename_len];
        fr.interface.readSliceAll(name) catch return error.InvalidZipArchive;
        if (std.mem.eql(u8, name, "payload.bin")) {
            entry.extract(&fr, .{}, &filename_buf, temp_dir) catch return error.InvalidZipArchive;
            const payload_path = try std.fmt.allocPrint(allocator, "{s}/payload.bin", .{dir_path});
            return .{ .temp_dir = dir_path, .payload_path = payload_path };
        }
    }

    allocator.free(dir_path);
    return error.PayloadNotFoundInZip;
}
