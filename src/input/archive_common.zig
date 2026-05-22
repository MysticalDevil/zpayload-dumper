const std = @import("std");
const errors = @import("../errors.zig");
const header = @import("../payload/header.zig");
const platform = @import("../utils/platform.zig");

pub const Error = errors.AppError;

pub const ExtractResult = struct {
    temp_dir: []u8,
    payload_path: []u8,
};

pub const PayloadMetadata = struct {
    manifest: []u8,

    pub fn deinit(self: *PayloadMetadata, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest);
    }
};

pub const TempBaseSelection = struct {
    base_path: []u8,
    is_absolute: bool,
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
    _: header.Header,
    manifest_bytes: []const u8,
) Error!PayloadMetadata {
    const manifest = try allocator.dupe(u8, manifest_bytes);
    return .{ .manifest = manifest };
}

pub fn selectTempBase(allocator: std.mem.Allocator) Error!TempBaseSelection {
    return .{
        .base_path = try allocator.dupe(u8, platform.fallback_tmp_base),
        .is_absolute = false,
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
) !ExtractResult {
    const payload_path = try std.fmt.allocPrint(allocator, "{s}/payload.bin", .{dir_path});
    return .{
        .temp_dir = dir_path,
        .payload_path = payload_path,
    };
}
