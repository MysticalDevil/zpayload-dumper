const std = @import("std");
const errors = @import("../errors.zig");
const common = @import("archive_common.zig");
const flate = std.compress.flate;

pub const Error = errors.AppError;
pub const TarExtractResult = common.ExtractResult;
pub const PayloadMetadata = common.PayloadMetadata;
pub const cleanupExtractedPayloadTempDir = common.cleanupExtractedPayloadTempDir;

fn isGzipped(tar_path: []const u8) bool {
    return std.mem.endsWith(u8, tar_path, ".tar.gz") or std.mem.endsWith(u8, tar_path, ".tgz");
}

pub fn extractPayloadBinFromTar(
    allocator: std.mem.Allocator,
    io: std.Io,
    tar_path: []const u8,
) Error!TarExtractResult {
    var tar_file = std.Io.Dir.cwd().openFile(io, tar_path, .{}) catch return error.InvalidTarArchive;
    defer tar_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr = tar_file.reader(io, &reader_buf);

    if (isGzipped(tar_path)) {
        var flate_buffer: [flate.max_window_len]u8 = undefined;
        var decompress: flate.Decompress = .init(&fr.interface, .gzip, &flate_buffer);
        return try extractFromTarReader(allocator, io, &decompress.reader);
    } else {
        return try extractFromTarReader(allocator, io, &fr.interface);
    }
}

fn extractFromTarReader(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: *std.Io.Reader,
) Error!TarExtractResult {
    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var iter = std.tar.Iterator.init(reader, .{
        .file_name_buffer = &file_name_buf,
        .link_name_buffer = &link_name_buf,
    });

    while (iter.next() catch return error.InvalidTarArchive) |file| {
        if (file.kind != .file) continue;
        if (!std.mem.eql(u8, file.name, "payload.bin")) continue;

        const base = try common.selectTempBase(allocator);
        defer allocator.free(base.base_path);
        return try attemptExtractPayloadFile(allocator, io, &iter, file, base);
    }

    return error.PayloadNotFoundInTar;
}

pub fn readPayloadMetadataFromTar(allocator: std.mem.Allocator, io: std.Io, tar_path: []const u8) Error!PayloadMetadata {
    var tar_file = std.Io.Dir.cwd().openFile(io, tar_path, .{}) catch return error.InvalidTarArchive;
    defer tar_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr = tar_file.reader(io, &reader_buf);

    if (isGzipped(tar_path)) {
        var flate_buffer: [flate.max_window_len]u8 = undefined;
        var decompress: flate.Decompress = .init(&fr.interface, .gzip, &flate_buffer);
        return try readMetadataFromTarReader(allocator, &decompress.reader);
    } else {
        return try readMetadataFromTarReader(allocator, &fr.interface);
    }
}

fn readMetadataFromTarReader(allocator: std.mem.Allocator, reader: *std.Io.Reader) Error!PayloadMetadata {
    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var iter = std.tar.Iterator.init(reader, .{
        .file_name_buffer = &file_name_buf,
        .link_name_buffer = &link_name_buf,
    });

    while (iter.next() catch return error.InvalidTarArchive) |file| {
        if (file.kind != .file) continue;
        if (!std.mem.eql(u8, file.name, "payload.bin")) continue;

        const header_prefix = try readTarEntryPrefixAlloc(allocator, reader, file, 24);
        defer allocator.free(header_prefix);

        const payload_header = try common.parsePayloadHeaderBytes(header_prefix);
        const manifest_len = std.math.cast(usize, payload_header.manifest_len) orelse return error.IntegerOverflow;
        const manifest_bytes = try readTarEntryPrefixAlloc(allocator, reader, file, manifest_len);
        defer allocator.free(manifest_bytes);

        return try common.metadataFromHeaderAndPrefix(allocator, payload_header, manifest_bytes);
    }

    return error.PayloadNotFoundInTar;
}

fn readTarEntryPrefixAlloc(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    file: std.tar.Iterator.File,
    prefix_len: usize,
) Error![]u8 {
    if (prefix_len > file.size) return error.TarDecompressTruncated;

    const bytes = try allocator.alloc(u8, prefix_len);
    errdefer allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);

    reader.streamExact64(&writer, prefix_len) catch |err| switch (err) {
        error.EndOfStream => return error.TarDecompressTruncated,
        else => return error.ArchiveReadFailed,
    };
    return bytes;
}

fn attemptExtractPayloadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    iter: *std.tar.Iterator,
    file: std.tar.Iterator.File,
    temp_base: common.TempBaseSelection,
) Error!TarExtractResult {
    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/zpayload_{d}", .{ temp_base.base_path, nonce });
    errdefer allocator.free(dir_path);

    try common.createTempBaseIfNeeded(io, temp_base.base_path, temp_base.is_absolute);
    try common.createTempDir(io, dir_path, temp_base.is_absolute);
    errdefer common.cleanupExtractedPayloadTempDir(io, dir_path) catch |cleanup_err| {
        std.log.warn("failed to cleanup temporary extraction directory '{s}': {}", .{ dir_path, cleanup_err });
    };

    try extractTarFileIntoDir(io, iter, file, dir_path, temp_base.is_absolute);

    return try common.makeExtractResult(allocator, dir_path);
}

fn extractTarFileIntoDir(
    io: std.Io,
    iter: *std.tar.Iterator,
    file: std.tar.Iterator.File,
    dir_path: []const u8,
    is_absolute: bool,
) Error!void {
    var temp_dir = if (is_absolute)
        std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return error.TempDirectoryCreateFailed
    else
        std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return error.TempDirectoryCreateFailed;
    defer temp_dir.close(io);

    var out_file = temp_dir.createFile(io, "payload.bin", .{}) catch |err| switch (err) {
        error.NoSpaceLeft, error.FileTooBig => return error.InsufficientDiskSpace,
        else => return error.ArchiveWriteFailed,
    };
    defer out_file.close(io);

    var buf: [65536]u8 = undefined;
    var remaining: u64 = file.size;
    while (remaining > 0) {
        const chunk_size = @min(buf.len, remaining);
        iter.reader.readSliceAll(buf[0..chunk_size]) catch |err| switch (err) {
            error.EndOfStream => return error.TarDecompressTruncated,
            else => return error.ArchiveReadFailed,
        };
        out_file.writeStreamingAll(io, buf[0..chunk_size]) catch |err| switch (err) {
            error.NoSpaceLeft, error.DiskQuota, error.FileTooBig => return error.InsufficientDiskSpace,
            else => return error.ArchiveWriteFailed,
        };
        remaining -= chunk_size;
    }
}
