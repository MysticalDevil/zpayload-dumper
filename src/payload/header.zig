const std = @import("std");
const errors = @import("../errors.zig");

pub const Error = errors.AppError;

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
    try readPositionalExact(file, io, &buf, off);
    return std.mem.readInt(u64, &buf, .big);
}

pub fn readU32Be(file: std.Io.File, io: std.Io, off: u64) Error!u32 {
    var buf: [4]u8 = undefined;
    try readPositionalExact(file, io, &buf, off);
    return std.mem.readInt(u32, &buf, .big);
}

pub fn readAtAlloc(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, off: u64, len_u64: u64) Error![]u8 {
    const len = std.math.cast(usize, len_u64) orelse return error.IntegerOverflow;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    try readPositionalExact(file, io, buf, off);
    return buf;
}

fn readPositionalExact(file: std.Io.File, io: std.Io, buf: []u8, off: u64) Error!void {
    const read_count = file.readPositionalAll(io, buf, off) catch return error.IoFailure;
    if (read_count != buf.len) return error.IoFailure;
}

test "readAtAlloc returns IoFailure on truncated input" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, "{s}/truncated.bin", .{tmp.sub_path});
    defer allocator.free(path);

    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);
        var writer = file.writer(io, &.{});
        try writer.interface.writeAll("AB");
        try writer.flush();
    }

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    try std.testing.expectError(error.IoFailure, readAtAlloc(allocator, file, io, 0, 4));
}
