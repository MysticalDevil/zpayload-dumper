const std = @import("std");

const c = @cImport({
    @cInclude("bzlib.h");
    @cInclude("lzma.h");
    @cInclude("zstd.h");
});

pub const Error = error{
    IntegerOverflow,
    Bzip2DecompressFailed,
    ZstdDecompressFailed,
    XzDecompressFailed,
    DecompressedSizeMismatch,
} || std.mem.Allocator.Error;

pub fn decompressBz2(allocator: std.mem.Allocator, compressed: []const u8, expected_size: usize) Error![]u8 {
    if (compressed.len > std.math.maxInt(c_uint) or expected_size > std.math.maxInt(c_uint)) {
        return error.IntegerOverflow;
    }

    const out = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(out);

    var dest_len: c_uint = @intCast(expected_size);
    const rc = c.BZ2_bzBuffToBuffDecompress(
        @ptrCast(out.ptr),
        &dest_len,
        @constCast(@ptrCast(compressed.ptr)),
        @intCast(compressed.len),
        0,
        0,
    );
    if (rc != c.BZ_OK) return error.Bzip2DecompressFailed;
    if (dest_len != expected_size) return error.DecompressedSizeMismatch;
    return out;
}

pub fn decompressZstd(allocator: std.mem.Allocator, compressed: []const u8, expected_size: usize) Error![]u8 {
    const out = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(out);

    const n = c.ZSTD_decompress(out.ptr, out.len, compressed.ptr, compressed.len);
    if (c.ZSTD_isError(n) != 0) return error.ZstdDecompressFailed;
    if (n != expected_size) return error.DecompressedSizeMismatch;
    return out;
}

pub fn decompressXz(allocator: std.mem.Allocator, compressed: []const u8, expected_size: usize) Error![]u8 {
    const out = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(out);

    var memlimit: u64 = std.math.maxInt(u64);
    var in_pos: usize = 0;
    var out_pos: usize = 0;
    const ret = c.lzma_stream_buffer_decode(
        &memlimit,
        0,
        null,
        compressed.ptr,
        &in_pos,
        compressed.len,
        out.ptr,
        &out_pos,
        out.len,
    );
    if (ret != c.LZMA_OK) return error.XzDecompressFailed;
    if (out_pos != expected_size) return error.DecompressedSizeMismatch;
    return out;
}
