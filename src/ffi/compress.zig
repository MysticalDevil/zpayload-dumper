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
    defer _ = c.BZ2_bzDecompressEnd(&stream);

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

    return total_written;
}

pub fn decompressZstdToWriter(
    file: std.Io.File,
    io: std.Io,
    offset: u64,
    compressed_len: u64,
    hasher: *std.crypto.hash.sha2.Sha256,
    writer: *std.Io.Writer,
    in_buf: []u8,
    out_buf: []u8,
) Error!usize {

    const dstream = c.ZSTD_createDStream() orelse return error.ZstdDecompressFailed;
    defer _ = c.ZSTD_freeDStream(dstream);

    if (c.ZSTD_isError(c.ZSTD_initDStream(dstream)) != 0) return error.ZstdDecompressFailed;

    var remaining = compressed_len;
    var pos = offset;
    var total_written: usize = 0;

    while (remaining > 0) {
        const n: usize = @intCast(@min(remaining, in_buf.len));
        const read_count = file.readPositionalAll(io, in_buf[0..n], pos) catch return error.IoFailure;
        std.debug.assert(read_count == n);
        hasher.update(in_buf[0..n]);
        pos += n;
        remaining -= n;

        var zin = c.ZSTD_inBuffer{
            .src = in_buf[0..n].ptr,
            .size = n,
            .pos = 0,
        };
        while (zin.pos < zin.size) {
            var zout = c.ZSTD_outBuffer{
                .dst = out_buf[0..].ptr,
                .size = out_buf.len,
                .pos = 0,
            };
            if (c.ZSTD_isError(c.ZSTD_decompressStream(dstream, &zout, &zin)) != 0) {
                return error.ZstdDecompressFailed;
            }
            if (zout.pos > 0) {
                writer.writeAll(out_buf[0..zout.pos]) catch return error.IoFailure;
                total_written += zout.pos;
            }
        }
    }

    return total_written;
}

pub fn decompressXzToWriter(
    file: std.Io.File,
    io: std.Io,
    offset: u64,
    compressed_len: u64,
    hasher: *std.crypto.hash.sha2.Sha256,
    writer: *std.Io.Writer,
    in_buf: []u8,
    out_buf: []u8,
) Error!usize {

    var stream: c.lzma_stream = std.mem.zeroes(c.lzma_stream);
    const init_rc = c.lzma_stream_decoder(&stream, std.math.maxInt(u64), 0);
    if (init_rc != c.LZMA_OK) return error.XzDecompressFailed;
    defer _ = c.lzma_end(&stream);

    var remaining = compressed_len;
    var pos = offset;
    var total_written: usize = 0;

    while (true) {
        const read_n: usize = if (remaining == 0) 0 else @intCast(@min(remaining, in_buf.len));
        if (read_n > 0) {
            const read_count = file.readPositionalAll(io, in_buf[0..read_n], pos) catch return error.IoFailure;
            std.debug.assert(read_count == read_n);
            hasher.update(in_buf[0..read_n]);
            pos += read_n;
            remaining -= read_n;
        }

        stream.next_in = if (read_n > 0) in_buf[0..read_n].ptr else null;
        stream.avail_in = read_n;

        while (true) {
            stream.next_out = out_buf[0..].ptr;
            stream.avail_out = @intCast(out_buf.len);
            const action: c.lzma_action = if (remaining == 0 and stream.avail_in == 0) c.LZMA_FINISH else c.LZMA_RUN;
            const rc = c.lzma_code(&stream, action);

            const produced = out_buf.len - stream.avail_out;
            if (produced > 0) {
                writer.writeAll(out_buf[0..produced]) catch return error.IoFailure;
                total_written += produced;
            }
            if (rc == c.LZMA_STREAM_END) return total_written;
            if (rc != c.LZMA_OK) return error.XzDecompressFailed;
            if (stream.avail_in == 0 and produced == 0) break;
        }

        if (remaining == 0 and read_n == 0) return error.XzDecompressFailed;
    }
}
