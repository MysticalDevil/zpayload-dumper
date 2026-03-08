const std = @import("std");
const errors = @import("../errors.zig");

pub const Error = errors.PayloadError || errors.SystemError;

pub const Header = struct {
    version: u64 = 0,
    manifest_len: u64 = 0,
    metadata_signature_len: u64 = 0,
};

pub fn readHeader(file: std.Io.File, io: std.Io) Error!Header {
    const magic = try readAtAlloc(std.heap.page_allocator, file, io, 0, 4);
    defer std.heap.page_allocator.free(magic);
    if (!std.mem.eql(u8, magic, "CrAU")) return error.InvalidMagic;

    const version = try readU64Be(file, io, 4);
    if (version != 2) return error.UnsupportedPayloadVersion;

    const manifest_len = try readU64Be(file, io, 12);
    const sig_len = try readU32Be(file, io, 20);

    return .{
        .version = version,
        .manifest_len = manifest_len,
        .metadata_signature_len = sig_len,
    };
}

pub fn readU64Be(file: std.Io.File, io: std.Io, off: u64) Error!u64 {
    var buf: [8]u8 = undefined;
    _ = file.readPositionalAll(io, &buf, off) catch return error.IoFailure;
    return std.mem.readInt(u64, &buf, .big);
}

pub fn readU32Be(file: std.Io.File, io: std.Io, off: u64) Error!u32 {
    var buf: [4]u8 = undefined;
    _ = file.readPositionalAll(io, &buf, off) catch return error.IoFailure;
    return std.mem.readInt(u32, &buf, .big);
}

pub fn readAtAlloc(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, off: u64, len_u64: u64) Error![]u8 {
    const len = std.math.cast(usize, len_u64) orelse return error.IntegerOverflow;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    _ = file.readPositionalAll(io, buf, off) catch return error.IoFailure;
    return buf;
}
