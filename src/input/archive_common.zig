const std = @import("std");
const errors = @import("../errors.zig");
const header = @import("../payload/header.zig");

pub const Error = errors.AppError;

pub const ExtractResult = struct {
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

pub const TempBaseSelection = struct {
    base_path: []u8,
    is_absolute: bool,
    used_fallback: bool,
};

pub fn cleanupExtractedPayloadTempDir(io: std.Io, path: []const u8) Error!void {
    if (std.fs.path.isAbsolute(path)) {
        const parent_path = std.fs.path.dirname(path) orelse return error.TempDirectoryCleanupFailed;
        const basename = std.fs.path.basename(path);
        var parent_dir = std.Io.Dir.openDirAbsolute(io, parent_path, .{}) catch return error.TempDirectoryCleanupFailed;
        defer parent_dir.close(io);
        parent_dir.deleteTree(io, basename) catch return error.TempDirectoryCleanupFailed;
        return;
    }

    std.Io.Dir.cwd().deleteTree(io, path) catch return error.TempDirectoryCleanupFailed;
}

pub fn parsePayloadHeaderBytes(prefix: []const u8) Error!header.Header {
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

pub fn metadataFromHeaderAndPrefix(
    allocator: std.mem.Allocator,
    payload_header: header.Header,
    manifest_sig: []const u8,
) Error!PayloadMetadata {
    const manifest_len = std.math.cast(usize, payload_header.manifest_len) orelse return error.IntegerOverflow;
    const signature_len = std.math.cast(usize, payload_header.metadata_signature_len) orelse return error.IntegerOverflow;
    if (manifest_sig.len != manifest_len + signature_len) return error.IntegerOverflow;

    const manifest = try allocator.dupe(u8, manifest_sig[0..manifest_len]);
    errdefer allocator.free(manifest);
    const signature = try allocator.dupe(u8, manifest_sig[manifest_len..]);
    return .{
        .manifest = manifest,
        .signature = signature,
    };
}

pub fn selectTempBase(
    allocator: std.mem.Allocator,
    preferred_base: []const u8,
    required_bytes: u64,
) Error!TempBaseSelection {
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

pub fn createTempBaseIfNeeded(io: std.Io, base_path: []const u8, is_absolute: bool) Error!void {
    if (is_absolute) {
        std.Io.Dir.createDirAbsolute(io, base_path, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return error.TempDirectoryCreateFailed,
        };
    } else {
        std.Io.Dir.cwd().createDirPath(io, base_path) catch return error.TempDirectoryCreateFailed;
    }
}

pub fn createTempDir(io: std.Io, dir_path: []const u8, is_absolute: bool) Error!void {
    if (is_absolute) {
        std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch return error.TempDirectoryCreateFailed;
        return;
    }
    std.Io.Dir.cwd().createDir(io, dir_path, .default_dir) catch return error.TempDirectoryCreateFailed;
}

pub fn makeExtractResult(
    allocator: std.mem.Allocator,
    dir_path: []u8,
    used_fallback_tmp: bool,
) !ExtractResult {
    const payload_path = try std.fmt.allocPrint(allocator, "{s}/payload.bin", .{dir_path});
    return .{
        .temp_dir = dir_path,
        .payload_path = payload_path,
        .used_fallback_tmp = used_fallback_tmp,
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
