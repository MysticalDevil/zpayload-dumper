const std = @import("std");
const errors = @import("../errors.zig");
const common = @import("archive_common.zig");
const platform = @import("../utils/platform.zig");
const flate = std.compress.flate;

pub const Error = errors.AppError;
pub const ZipExtractResult = common.ExtractResult;
pub const PayloadMetadata = common.PayloadMetadata;

const FileExtents = struct {
    uncompressed_size: u64,
    compressed_size: u64,
};

pub const cleanupExtractedPayloadTempDir = common.cleanupExtractedPayloadTempDir;

pub fn extractPayloadBinFromZip(allocator: std.mem.Allocator, io: std.Io, tmp_base: []const u8, zip_path: []const u8) Error!ZipExtractResult {
    var zip_file = std.Io.Dir.cwd().openFile(io, zip_path, .{}) catch return error.InvalidZipArchive;
    defer zip_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr = zip_file.reader(io, &reader_buf);
    var iter = std.zip.Iterator.init(&fr) catch return error.InvalidZipArchive;
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (iter.next() catch return error.InvalidZipArchive) |entry| {
        fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch return error.InvalidZipArchive;
        const name = filename_buf[0..entry.filename_len];
        fr.interface.readSliceAll(name) catch return error.ArchiveReadFailed;
        if (std.mem.eql(u8, name, "payload.bin")) {
            const preferred_base = try common.selectTempBase(allocator, tmp_base, entry.uncompressed_size);
            defer allocator.free(preferred_base.base_path);

            if (try attemptExtractPayloadEntry(allocator, io, &fr, entry, &filename_buf, preferred_base, true)) |result| {
                return result;
            }

            if (preferred_base.used_fallback) return error.InsufficientDiskSpace;

            const fallback_base = common.TempBaseSelection{
                .base_path = try allocator.dupe(u8, platform.fallback_tmp_base),
                .is_absolute = false,
                .used_fallback = true,
            };
            defer allocator.free(fallback_base.base_path);

            if (try attemptExtractPayloadEntry(allocator, io, &fr, entry, &filename_buf, fallback_base, true)) |result| {
                return result;
            }
            return error.InsufficientDiskSpace;
        }
    }

    return error.PayloadNotFoundInZip;
}

pub fn readPayloadMetadataFromZip(allocator: std.mem.Allocator, io: std.Io, zip_path: []const u8) Error!PayloadMetadata {
    var zip_file = std.Io.Dir.cwd().openFile(io, zip_path, .{}) catch return error.InvalidZipArchive;
    defer zip_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr = zip_file.reader(io, &reader_buf);
    var iter = std.zip.Iterator.init(&fr) catch return error.InvalidZipArchive;
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    while (iter.next() catch return error.InvalidZipArchive) |entry| {
        fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch return error.InvalidZipArchive;
        const name = filename_buf[0..entry.filename_len];
        fr.interface.readSliceAll(name) catch return error.ArchiveReadFailed;
        if (!std.mem.eql(u8, name, "payload.bin")) continue;

        const header_prefix = try readEntryPrefixAlloc(allocator, &fr, entry, 24);
        defer allocator.free(header_prefix);

        const payload_header = try common.parsePayloadHeaderBytes(header_prefix);
        const total_prefix_len_u64 = 24 + payload_header.manifest_len + payload_header.metadata_signature_len;
        const total_prefix_len = std.math.cast(usize, total_prefix_len_u64) orelse return error.IntegerOverflow;
        const full_prefix = try readEntryPrefixAlloc(allocator, &fr, entry, total_prefix_len);
        defer allocator.free(full_prefix);

        return try common.metadataFromHeaderAndPrefix(allocator, payload_header, full_prefix[24..]);
    }

    return error.PayloadNotFoundInZip;
}

fn readEntryPrefixAlloc(
    allocator: std.mem.Allocator,
    fr: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    prefix_len: usize,
) Error![]u8 {
    const prefix_len_u64: u64 = @intCast(prefix_len);
    if (prefix_len_u64 > entry.uncompressed_size) return error.ZipDecompressTruncated;

    fr.seekTo(entry.file_offset) catch return error.InvalidZipArchive;
    const local_header = fr.interface.takeStruct(std.zip.LocalFileHeader, .little) catch return error.ZipDecompressTruncated;
    if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig)) return error.InvalidZipArchive;
    if (local_header.version_needed_to_extract != entry.version_needed_to_extract) return error.InvalidZipArchive;
    if (local_header.last_modification_time != entry.last_modification_time) return error.InvalidZipArchive;
    if (local_header.last_modification_date != entry.last_modification_date) return error.InvalidZipArchive;
    if (@as(u16, @bitCast(local_header.flags)) != @as(u16, @bitCast(entry.flags))) return error.InvalidZipArchive;
    if (local_header.crc32 != 0 and local_header.crc32 != entry.crc32) return error.InvalidZipArchive;
    if (local_header.filename_len != entry.filename_len) return error.InvalidZipArchive;

    var extents: FileExtents = .{
        .uncompressed_size = local_header.uncompressed_size,
        .compressed_size = local_header.compressed_size,
    };
    if (local_header.extra_len > 0) {
        const extra = try allocator.alloc(u8, local_header.extra_len);
        defer allocator.free(extra);

        fr.seekTo(entry.file_offset + @sizeOf(std.zip.LocalFileHeader) + local_header.filename_len) catch return error.InvalidZipArchive;
        fr.interface.readSliceAll(extra) catch return error.ZipDecompressTruncated;

        var extra_offset: usize = 0;
        while (extra_offset + 4 <= extra.len) {
            const header_id = std.mem.readInt(u16, extra[extra_offset..][0..2], .little);
            const data_size = std.mem.readInt(u16, extra[extra_offset..][2..4], .little);
            const end = extra_offset + 4 + data_size;
            if (end > extra.len) return error.InvalidZipArchive;
            const data = extra[extra_offset + 4 .. end];
            switch (@as(std.zip.ExtraHeader, @enumFromInt(header_id))) {
                .zip64_info => try readZip64LocalExtents(local_header, &extents, data),
                else => {},
            }
            extra_offset = end;
        }
    }
    if (extents.compressed_size != 0 and extents.compressed_size != entry.compressed_size) return error.InvalidZipArchive;
    if (extents.uncompressed_size != 0 and extents.uncompressed_size != entry.uncompressed_size) return error.InvalidZipArchive;

    const local_data_file_offset =
        entry.file_offset +
        @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        @as(u64, local_header.filename_len) +
        @as(u64, local_header.extra_len);
    fr.seekTo(local_data_file_offset) catch return error.InvalidZipArchive;

    var limited_buf: [4096]u8 = undefined;
    var limited = std.Io.Reader.Limited.init(&fr.interface, .limited(entry.compressed_size), &limited_buf);

    const bytes = try allocator.alloc(u8, prefix_len);
    errdefer allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);

    switch (entry.compression_method) {
        .store => {
            limited.interface.streamExact64(&writer, prefix_len_u64) catch return error.ZipDecompressTruncated;
        },
        .deflate => {
            var flate_buffer: [flate.max_window_len]u8 = undefined;
            var decompress: flate.Decompress = .init(&limited.interface, .raw, &flate_buffer);
            decompress.reader.streamExact64(&writer, prefix_len_u64) catch return error.ZipDecompressTruncated;
        },
        else => return error.InvalidZipArchive,
    }

    return bytes;
}

fn readZip64LocalExtents(
    local_header: std.zip.LocalFileHeader,
    extents: *FileExtents,
    data: []const u8,
) Error!void {
    var data_offset: usize = 0;
    if (local_header.uncompressed_size == std.math.maxInt(u32)) {
        if (data_offset + 8 > data.len) return error.InvalidZipArchive;
        extents.uncompressed_size = std.mem.readInt(u64, data[data_offset..][0..8], .little);
        data_offset += 8;
    }
    if (local_header.compressed_size == std.math.maxInt(u32)) {
        if (data_offset + 8 > data.len) return error.InvalidZipArchive;
        extents.compressed_size = std.mem.readInt(u64, data[data_offset..][0..8], .little);
    }
}

fn attemptExtractPayloadEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    fr: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    filename_buf: []u8,
    temp_base: common.TempBaseSelection,
    allow_space_retry: bool,
) Error!?ZipExtractResult {
    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/zpayload_{d}", .{ temp_base.base_path, nonce });
    errdefer allocator.free(dir_path);

    try common.createTempBaseIfNeeded(io, temp_base.base_path, temp_base.is_absolute);
    try common.createTempDir(io, dir_path, temp_base.is_absolute);
    errdefer common.cleanupExtractedPayloadTempDir(io, dir_path) catch |cleanup_err| {
        std.log.warn("failed to cleanup temporary extraction directory '{s}': {}", .{ dir_path, cleanup_err });
    };

    extractEntryIntoDir(io, fr, entry, filename_buf, dir_path, temp_base.is_absolute) catch |err| {
        if (allow_space_retry and err == error.InsufficientDiskSpace) {
            allocator.free(dir_path);
            return null;
        }
        return err;
    };

    return try common.makeExtractResult(allocator, dir_path, temp_base.used_fallback);
}

fn extractEntryIntoDir(
    io: std.Io,
    fr: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    filename_buf: []u8,
    dir_path: []const u8,
    is_absolute: bool,
) Error!void {
    if (is_absolute) {
        var temp_dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return error.TempDirectoryCreateFailed;
        defer temp_dir.close(io);
        entry.extract(fr, .{}, filename_buf, temp_dir) catch |err| switch (err) {
            error.NoSpaceLeft, error.FileTooBig, error.WriteFailed => return error.InsufficientDiskSpace,
            error.EndOfStream => return error.ZipDecompressTruncated,
            else => return error.ArchiveWriteFailed,
        };
        return;
    }

    var temp_dir = std.Io.Dir.cwd().openDir(io, dir_path, .{}) catch return error.TempDirectoryCreateFailed;
    defer temp_dir.close(io);
    entry.extract(fr, .{}, filename_buf, temp_dir) catch |err| switch (err) {
        error.NoSpaceLeft, error.FileTooBig, error.WriteFailed => return error.InsufficientDiskSpace,
        error.EndOfStream => return error.ZipDecompressTruncated,
        else => return error.ArchiveWriteFailed,
    };
}
