const std = @import("std");
const errors = @import("../errors.zig");
const header = @import("../payload/header.zig");
const flate = std.compress.flate;

pub const Error = errors.AppError;

pub const ZipExtractResult = struct {
    temp_dir: []u8,
    payload_path: []u8,
    used_fallback_tmp: bool,
};

pub const PayloadMetadata = struct {
    manifest: []u8,
    signature: []u8,

    pub fn deinit(self: *PayloadMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest);
        allocator.free(self.signature);
    }
};

pub fn cleanupExtractedPayloadTempDir(io: std.Io, path: []const u8) Error!void {
    if (std.fs.path.isAbsolute(path)) {
        const parent_path = std.fs.path.dirname(path) orelse return error.IoFailure;
        const basename = std.fs.path.basename(path);
        var parent_dir = std.Io.Dir.openDirAbsolute(io, parent_path, .{}) catch return error.IoFailure;
        defer parent_dir.close(io);
        parent_dir.deleteTree(io, basename) catch return error.IoFailure;
        return;
    }

    std.Io.Dir.cwd().deleteTree(io, path) catch return error.IoFailure;
}

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
        fr.interface.readSliceAll(name) catch return error.InvalidZipArchive;
        if (std.mem.eql(u8, name, "payload.bin")) {
            const preferred_base = selectTempBase(allocator, tmp_base, entry.uncompressed_size) catch return error.IoFailure;
            defer allocator.free(preferred_base.base_path);

            if (try attemptExtractPayloadEntry(allocator, io, &fr, entry, &filename_buf, preferred_base, true)) |result| {
                return result;
            }

            if (preferred_base.used_fallback) return error.IoFailure;

            const fallback_base = TempBaseSelection{
                .base_path = try allocator.dupe(u8, ".tmp"),
                .is_absolute = false,
                .used_fallback = true,
            };
            defer allocator.free(fallback_base.base_path);

            if (try attemptExtractPayloadEntry(allocator, io, &fr, entry, &filename_buf, fallback_base, true)) |result| {
                return result;
            }
            return error.IoFailure;
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
        fr.interface.readSliceAll(name) catch return error.InvalidZipArchive;
        if (!std.mem.eql(u8, name, "payload.bin")) continue;

        const header_prefix = readEntryPrefixAlloc(allocator, &fr, entry, 24) catch return error.InvalidZipArchive;
        defer allocator.free(header_prefix);

        const payload_header = parseHeaderBytes(header_prefix) catch return error.InvalidZipArchive;
        const total_prefix_len_u64 = 24 + payload_header.manifest_len + payload_header.metadata_signature_len;
        const total_prefix_len = std.math.cast(usize, total_prefix_len_u64) orelse return error.IntegerOverflow;
        const full_prefix = readEntryPrefixAlloc(allocator, &fr, entry, total_prefix_len) catch return error.InvalidZipArchive;
        defer allocator.free(full_prefix);

        const manifest_start: usize = 24;
        const manifest_end = manifest_start + (std.math.cast(usize, payload_header.manifest_len) orelse return error.IntegerOverflow);
        const signature_end = manifest_end + (std.math.cast(usize, payload_header.metadata_signature_len) orelse return error.IntegerOverflow);

        const manifest = try allocator.dupe(u8, full_prefix[manifest_start..manifest_end]);
        errdefer allocator.free(manifest);
        const signature = try allocator.dupe(u8, full_prefix[manifest_end..signature_end]);
        return .{
            .manifest = manifest,
            .signature = signature,
        };
    }

    return error.PayloadNotFoundInZip;
}

fn parseHeaderBytes(prefix: []const u8) Error!header.Header {
    if (prefix.len < 24) return error.InvalidMagic;
    if (!std.mem.eql(u8, prefix[0..4], "CrAU")) return error.InvalidMagic;

    const version = std.mem.readInt(u64, prefix[4..12], .big);
    if (version != 2) return error.UnsupportedPayloadVersion;
    const manifest_len = std.mem.readInt(u64, prefix[12..20], .big);
    const sig_len = std.mem.readInt(u32, prefix[20..24], .big);

    return .{
        .version = version,
        .manifest_len = manifest_len,
        .metadata_signature_len = sig_len,
    };
}

fn readEntryPrefixAlloc(
    allocator: std.mem.Allocator,
    fr: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    prefix_len: usize,
) ![]u8 {
    const prefix_len_u64: u64 = @intCast(prefix_len);
    if (prefix_len_u64 > entry.uncompressed_size) return error.ZipDecompressTruncated;

    try fr.seekTo(entry.file_offset);
    const local_header = try fr.interface.takeStruct(std.zip.LocalFileHeader, .little);
    if (!std.mem.eql(u8, &local_header.signature, &std.zip.local_file_header_sig)) return error.ZipBadFileOffset;
    if (local_header.filename_len != entry.filename_len) return error.ZipMismatchFilenameLen;

    const local_data_file_offset =
        entry.file_offset +
        @as(u64, @sizeOf(std.zip.LocalFileHeader)) +
        @as(u64, local_header.filename_len) +
        @as(u64, local_header.extra_len);
    try fr.seekTo(local_data_file_offset);

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

const TempBaseSelection = struct {
    base_path: []u8,
    is_absolute: bool,
    used_fallback: bool,
};

fn attemptExtractPayloadEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    fr: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    filename_buf: []u8,
    temp_base: TempBaseSelection,
    allow_space_retry: bool,
) Error!?ZipExtractResult {
    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/zpayload_{d}", .{ temp_base.base_path, nonce });
    errdefer allocator.free(dir_path);

    createTempBaseIfNeeded(io, temp_base.base_path, temp_base.is_absolute) catch return error.IoFailure;
    createTempDir(io, dir_path, temp_base.is_absolute) catch return error.IoFailure;
    errdefer cleanupExtractedPayloadTempDir(io, dir_path) catch {};

    const extract_err = extractEntryIntoDir(io, fr, entry, filename_buf, dir_path, temp_base.is_absolute);
    if (extract_err) |_| {} else |err| {
        if (allow_space_retry and shouldRetryWithFallback(err)) {
            allocator.free(dir_path);
            return null;
        }
        return mapZipExtractError(err);
    }

    const payload_path = try std.fmt.allocPrint(allocator, "{s}/payload.bin", .{dir_path});
    return .{
        .temp_dir = dir_path,
        .payload_path = payload_path,
        .used_fallback_tmp = temp_base.used_fallback,
    };
}

fn createTempDir(io: std.Io, dir_path: []const u8, is_absolute: bool) !void {
    if (is_absolute) {
        try std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir);
        return;
    }
    try std.Io.Dir.cwd().createDir(io, dir_path, .default_dir);
}

fn extractEntryIntoDir(
    io: std.Io,
    fr: *std.Io.File.Reader,
    entry: std.zip.Iterator.Entry,
    filename_buf: []u8,
    dir_path: []const u8,
    is_absolute: bool,
) anyerror!void {
    if (is_absolute) {
        var temp_dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
        defer temp_dir.close(io);
        try entry.extract(fr, .{}, filename_buf, temp_dir);
        return;
    }

    var temp_dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer temp_dir.close(io);
    try entry.extract(fr, .{}, filename_buf, temp_dir);
}

fn shouldRetryWithFallback(err: anyerror) bool {
    return switch (err) {
        error.NoSpaceLeft,
        error.DiskQuota,
        error.FileTooBig,
        error.WriteFailed,
        => true,
        else => false,
    };
}

fn mapZipExtractError(err: anyerror) Error {
    return switch (err) {
        error.NoSpaceLeft,
        error.DiskQuota,
        error.FileTooBig,
        error.WriteFailed,
        => error.IoFailure,
        else => error.InvalidZipArchive,
    };
}

const StatVfs = extern struct {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: u64,
    f_flag: u64,
    f_namemax: u64,
    __f_spare: [6]c_int,
};

extern "c" fn statvfs(path: [*:0]const u8, buf: *StatVfs) c_int;

fn selectTempBase(allocator: std.mem.Allocator, preferred_base: []const u8, required_bytes: u64) !TempBaseSelection {
    const fallback_base = ".tmp";
    const preferred_available = getAvailableBytes(preferred_base) catch 0;
    if (preferred_available >= required_bytes) {
        return .{
            .base_path = try allocator.dupe(u8, preferred_base),
            .is_absolute = std.fs.path.isAbsolute(preferred_base),
            .used_fallback = false,
        };
    }
    return .{
        .base_path = try allocator.dupe(u8, fallback_base),
        .is_absolute = false,
        .used_fallback = true,
    };
}

fn createTempBaseIfNeeded(io: std.Io, base_path: []const u8, is_absolute: bool) !void {
    if (is_absolute) {
        std.Io.Dir.createDirAbsolute(io, base_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    } else {
        std.Io.Dir.cwd().createDirPath(io, base_path) catch return error.IoFailure;
    }
}

fn getAvailableBytes(path: []const u8) !u64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.NoSpaceLeft;
    var buf: StatVfs = undefined;
    if (statvfs(path_z.ptr, &buf) != 0) return error.InputOutput;
    return buf.f_bavail * buf.f_frsize;
}

test "selectTempBase falls back when preferred space is insufficient" {
    const allocator = std.testing.allocator;

    const selection = try selectTempBase(allocator, "/tmp", std.math.maxInt(u64));
    defer allocator.free(selection.base_path);

    try std.testing.expect(selection.used_fallback);
    try std.testing.expect(!selection.is_absolute);
    try std.testing.expectEqualStrings(".tmp", selection.base_path);
}
