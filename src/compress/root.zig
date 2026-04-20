const std = @import("std");
const errors = @import("../errors.zig");

const c = @import("compress");

pub const Error = errors.AppError;
pub const chunk_size = 128 * 1024;

pub fn copyRawToWriter(
    file: std.Io.File,
    io: std.Io,
    offset: u64,
    compressed_len: u64,
    hasher: *std.crypto.hash.sha2.Sha256,
    writer: *std.Io.Writer,
    in_buf: []u8,
) Error!usize {
    var remaining = compressed_len;
    var pos = offset;
    var total_written: usize = 0;

    while (remaining > 0) {
        const n: usize = @intCast(@min(remaining, in_buf.len));
        const read_count = file.readPositionalAll(io, in_buf[0..n], pos) catch return error.IoFailure;
        std.debug.assert(read_count == n);
        hasher.update(in_buf[0..n]);
        writer.writeAll(in_buf[0..n]) catch return error.IoFailure;
        total_written += n;
        remaining -= n;
        pos += n;
    }
    return total_written;
}

pub fn decompressBz2ToWriter(
    file: std.Io.File,
    io: std.Io,
    offset: u64,
    compressed_len: u64,
    hasher: *std.crypto.hash.sha2.Sha256,
    writer: *std.Io.Writer,
    in_buf: []u8,
    out_buf: []u8,
) Error!usize {

    var stream: c.bz_stream = std.mem.zeroes(c.bz_stream);
    if (c.BZ2_bzDecompressInit(&stream, 0, 0) != c.BZ_OK) return error.Bzip2DecompressFailed;
    errdefer _ = c.BZ2_bzDecompressEnd(&stream);

    var remaining = compressed_len;
    var pos = offset;
    var total_written: usize = 0;
    var in_pos: usize = 0;
    var in_len: usize = 0;

    while (true) {
        if (in_pos == in_len and remaining > 0) {
            in_len = @intCast(@min(remaining, in_buf.len));
            const read_count = file.readPositionalAll(io, in_buf[0..in_len], pos) catch return error.IoFailure;
            std.debug.assert(read_count == in_len);
            hasher.update(in_buf[0..in_len]);
            pos += in_len;
            remaining -= in_len;
            in_pos = 0;
        }

        stream.next_in = if (in_pos < in_len) @ptrCast(&in_buf[in_pos]) else null;
        stream.avail_in = @intCast(in_len - in_pos);
        stream.next_out = @ptrCast(out_buf.ptr);
        stream.avail_out = @intCast(out_buf.len);

        const rc = c.BZ2_bzDecompress(&stream);
        const consumed = (in_len - in_pos) - @as(usize, @intCast(stream.avail_in));
        in_pos += consumed;
        const produced = out_buf.len - @as(usize, @intCast(stream.avail_out));
        if (produced > 0) {
            writer.writeAll(out_buf[0..produced]) catch return error.IoFailure;
            total_written += produced;
        }

        if (rc == c.BZ_STREAM_END) break;
        if (rc != c.BZ_OK) return error.Bzip2DecompressFailed;
        if (remaining == 0 and in_pos == in_len and produced == 0) return error.Bzip2DecompressFailed;
    }

    if (c.BZ2_bzDecompressEnd(&stream) != c.BZ_OK) return error.Bzip2DecompressFailed;
    return total_written;
}

pub fn decompressZstdToWriter(
    file: std.Io.File,
    io: std.Io,
    offset: u64,
    compressed_len: u64,
    hasher: *std.crypto.hash.sha2.Sha256,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
) Error!usize {
    const data = allocator.alloc(u8, compressed_len) catch return error.OutOfMemory;
    defer allocator.free(data);

    const read_count = file.readPositionalAll(io, data, offset) catch return error.IoFailure;
    std.debug.assert(read_count == compressed_len);
    hasher.update(data);

    var fixed_reader = std.Io.Reader.fixed(data);
    var decompress = std.compress.zstd.Decompress.init(&fixed_reader, &.{}, .{});

    var total: usize = 0;
    while (true) {
        const n = decompress.reader.stream(writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.ZstdDecompressFailed,
        };
        total += n;
    }
    return total;
}

pub fn decompressXzToWriter(
    file: std.Io.File,
    io: std.Io,
    offset: u64,
    compressed_len: u64,
    hasher: *std.crypto.hash.sha2.Sha256,
    writer: *std.Io.Writer,
    allocator: std.mem.Allocator,
) Error!usize {
    const data = allocator.alloc(u8, compressed_len) catch return error.OutOfMemory;
    defer allocator.free(data);

    const read_count = file.readPositionalAll(io, data, offset) catch return error.IoFailure;
    std.debug.assert(read_count == compressed_len);
    hasher.update(data);

    var fixed_reader = std.Io.Reader.fixed(data);
    var decompress = std.compress.xz.Decompress.init(&fixed_reader, allocator, &.{}) catch return error.XzDecompressFailed;
    defer decompress.deinit();

    var total: usize = 0;
    while (true) {
        const n = decompress.reader.stream(writer, .unlimited) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return error.XzDecompressFailed,
        };
        total += n;
    }
    return total;
}
