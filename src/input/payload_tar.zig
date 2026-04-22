const std = @import("std");
const errors = @import("../errors.zig");
const header = @import("../payload/header.zig");
const flate = std.compress.flate;

pub const Error = errors.AppError;

pub const TarExtractResult = struct {
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

fn isGzipped(tar_path: []const u8) bool {
    return std.mem.endsWith(u8, tar_path, ".tar.gz") or std.mem.endsWith(u8, tar_path, ".tgz");
}

pub fn extractPayloadBinFromTar(allocator: std.mem.Allocator, io: std.Io, tar_path: []const u8) Error!TarExtractResult {
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

fn extractFromTarReader(allocator: std.mem.Allocator, io: std.Io, reader: *std.Io.Reader) Error!TarExtractResult {
    var file_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var iter = std.tar.Iterator.init(reader, .{
        .file_name_buffer = &file_name_buf,
        .link_name_buffer = &link_name_buf,
    });

    while (iter.next() catch return error.InvalidTarArchive) |file| {
        if (file.kind != .file) continue;
        if (!std.mem.eql(u8, file.name, "payload.bin")) continue;

        // Tar does not support random seek, so we cannot retry after reader
        // consumption fails. Use a single temp base that is known to work.
        const base = TempBaseSelection{
            .base_path = try allocator.dupe(u8, ".tmp"),
            .is_absolute = false,
            .used_fallback = false,
        };
        defer allocator.free(base.base_path);

        if (try attemptExtractPayloadFile(allocator, io, &iter, file, &file_name_buf, base, false)) |result| {
            return result;
        }
        return error.IoFailure;
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

        const header_prefix = readTarEntryPrefixAlloc(allocator, reader, file, 24) catch return error.InvalidTarArchive;
        defer allocator.free(header_prefix);

        const payload_header = parseHeaderBytes(header_prefix) catch return error.InvalidTarArchive;
        const total_prefix_len_u64 = 24 + payload_header.manifest_len + payload_header.metadata_signature_len;
        const total_prefix_len = std.math.cast(usize, total_prefix_len_u64) orelse return error.IntegerOverflow;

        const full_prefix = readTarEntryPrefixAlloc(allocator, reader, file, total_prefix_len) catch return error.InvalidTarArchive;
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

    return error.PayloadNotFoundInTar;
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

fn readTarEntryPrefixAlloc(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    file: std.tar.Iterator.File,
    prefix_len: usize,
) ![]u8 {
    if (prefix_len > file.size) return error.TarDecompressTruncated;

    const bytes = try allocator.alloc(u8, prefix_len);
    errdefer allocator.free(bytes);
    var writer: std.Io.Writer = .fixed(bytes);

    reader.streamExact64(&writer, prefix_len) catch return error.TarDecompressTruncated;
    return bytes;
}

const TempBaseSelection = struct {
    base_path: []u8,
    is_absolute: bool,
    used_fallback: bool,
};

fn attemptExtractPayloadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    iter: *std.tar.Iterator,
    file: std.tar.Iterator.File,
    filename_buf: []u8,
    temp_base: TempBaseSelection,
    allow_space_retry: bool,
) Error!?TarExtractResult {
    _ = filename_buf;

    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/zpayload_{d}", .{ temp_base.base_path, nonce });
    errdefer allocator.free(dir_path);

    createTempBaseIfNeeded(io, temp_base.base_path, temp_base.is_absolute) catch return error.IoFailure;
    createTempDir(io, dir_path, temp_base.is_absolute) catch return error.IoFailure;
    errdefer cleanupExtractedPayloadTempDir(io, dir_path) catch |cleanup_err| {
        std.log.warn("failed to cleanup temporary extraction directory '{s}': {}", .{ dir_path, cleanup_err });
    };

    const extract_err = extractTarFileIntoDir(io, iter, file, dir_path, temp_base.is_absolute);
    if (extract_err) |_| {} else |err| {
        if (allow_space_retry and shouldRetryWithFallback(err)) {
            allocator.free(dir_path);
            return null;
        }
        return mapTarExtractError(err);
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

fn extractTarFileIntoDir(
    io: std.Io,
    iter: *std.tar.Iterator,
    file: std.tar.Iterator.File,
    dir_path: []const u8,
    is_absolute: bool,
) anyerror!void {
    var temp_dir = if (is_absolute)
        try std.Io.Dir.openDirAbsolute(io, dir_path, .{})
    else
        try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer temp_dir.close(io);

    var out_file = try temp_dir.createFile(io, "payload.bin", .{});
    defer out_file.close(io);

    var buf: [65536]u8 = undefined;
    var remaining: u64 = file.size;
    while (remaining > 0) {
        const chunk_size = @min(buf.len, remaining);
        iter.reader.readSliceAll(buf[0..chunk_size]) catch return error.IoFailure;
        out_file.writeStreamingAll(io, buf[0..chunk_size]) catch return error.IoFailure;
        remaining -= chunk_size;
    }
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

fn mapTarExtractError(err: anyerror) Error {
    return switch (err) {
        error.NoSpaceLeft,
        error.DiskQuota,
        error.FileTooBig,
        error.WriteFailed,
        => error.IoFailure,
        else => error.InvalidTarArchive,
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
