const std = @import("std");

const c = @cImport({
    @cInclude("upb_wrap.h");
    @cInclude("bzlib.h");
    @cInclude("lzma.h");
    @cInclude("zstd.h");
});

pub const block_size: u64 = 4096;

const OP_REPLACE: i32 = 0;
const OP_REPLACE_BZ: i32 = 1;
const OP_ZERO: i32 = 6;
const OP_REPLACE_XZ: i32 = 8;
const OP_ZSTD: i32 = 14;

pub const Payload = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    header: Header = .{},
    metadata_size: u64 = 0,
    data_offset: u64 = 0,
    ctx: ?*c.zp_ctx = null,

    pub fn open(allocator: std.mem.Allocator, filename: []const u8) !Payload {
        const file = try std.fs.cwd().openFile(filename, .{});
        return .{
            .allocator = allocator,
            .file = file,
        };
    }

    pub fn deinit(self: *Payload) void {
        if (self.ctx) |ctx| c.zp_ctx_free(ctx);
        self.file.close();
    }

    pub fn init(self: *Payload) !void {
        self.header = try readHeader(self.file);

        const manifest_buf = try readAtAlloc(self.allocator, self.file, 24, self.header.manifest_len);
        defer self.allocator.free(manifest_buf);
        const signature_off = 24 + self.header.manifest_len;
        const signature_buf = try readAtAlloc(self.allocator, self.file, signature_off, self.header.metadata_signature_len);
        defer self.allocator.free(signature_buf);

        const ctx = c.zp_ctx_new(manifest_buf.ptr, manifest_buf.len, signature_buf.ptr, signature_buf.len);
        if (ctx == null) return error.ManifestOrSignatureDecodeFailed;
        self.ctx = ctx;

        self.metadata_size = 24 + self.header.manifest_len;
        self.data_offset = self.metadata_size + self.header.metadata_signature_len;
    }

    pub fn printPartitionList(self: *Payload, w: *std.Io.Writer) !void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        try w.writeAll("Found partitions:\n");
        const n = c.zp_partition_count(ctx);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            var name_len: usize = 0;
            const name_ptr = c.zp_partition_name(ctx, i, &name_len);
            if (name_ptr == null) continue;
            const name = name_ptr[0..name_len];
            const size = c.zp_partition_size(ctx, i);
            try w.print("  {s} ({d} bytes)\n", .{ name, size });
        }
    }

    pub fn extractAll(self: *Payload, output_dir: []const u8) !void {
        return self.extractSelected(output_dir, &.{});
    }

    pub fn extractSelected(self: *Payload, output_dir: []const u8, selected: []const []const u8) !void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        const n = c.zp_partition_count(ctx);
        var pidx: usize = 0;
        while (pidx < n) : (pidx += 1) {
            var name_len: usize = 0;
            const name_ptr = c.zp_partition_name(ctx, pidx, &name_len);
            if (name_ptr == null) continue;
            const name = name_ptr[0..name_len];
            if (selected.len != 0 and !containsPartition(selected, name)) continue;

            const out_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.img", .{ output_dir, name });
            defer self.allocator.free(out_path);

            var out = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
            defer out.close();
            try self.extractPartition(pidx, out);
        }
    }

    fn extractPartition(self: *Payload, pidx: usize, out: std.fs.File) !void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        const op_count = c.zp_operation_count(ctx, pidx);
        var oidx: usize = 0;
        while (oidx < op_count) : (oidx += 1) {
            const extent_count = c.zp_dst_extent_count(ctx, pidx, oidx);
            if (extent_count == 0) return error.InvalidDstExtents;

            const blob_len_u64 = c.zp_operation_data_length(ctx, pidx, oidx);
            const blob_off_u64 = c.zp_operation_data_offset(ctx, pidx, oidx);
            const blob_abs = self.data_offset + blob_off_u64;
            const blob = try readAtAlloc(self.allocator, self.file, blob_abs, blob_len_u64);
            defer self.allocator.free(blob);

            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(blob, &hash, .{});

            const expected_uncompressed = sumExtentBytes(ctx, pidx, oidx, extent_count);
            const op_type = c.zp_operation_type(ctx, pidx, oidx);

            switch (op_type) {
                OP_REPLACE => {
                    if (blob.len != expected_uncompressed) return error.UnexpectedBytesWritten;
                    try copyToExtents(ctx, pidx, oidx, extent_count, out, blob);
                },
                OP_REPLACE_XZ => {
                    const out_buf = try decompressXz(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, out, out_buf);
                },
                OP_REPLACE_BZ => {
                    const out_buf = try decompressBz2(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, out, out_buf);
                },
                OP_ZSTD => {
                    const out_buf = try decompressZstd(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, out, out_buf);
                },
                OP_ZERO => {
                    try writeZeroToExtents(self.allocator, ctx, pidx, oidx, extent_count, out);
                },
                else => return error.UnhandledOperationType,
            }

            var expected_len: usize = 0;
            const expected_ptr = c.zp_operation_data_sha256(ctx, pidx, oidx, &expected_len);
            if (expected_ptr != null and expected_len != 0) {
                const expected = expected_ptr[0..expected_len];
                if (!std.mem.eql(u8, expected, hash[0..])) return error.ChecksumMismatch;
            }
        }
    }
};

const Header = struct {
    version: u64 = 0,
    manifest_len: u64 = 0,
    metadata_signature_len: u64 = 0,
};

fn readHeader(file: std.fs.File) !Header {
    const magic = try readAtAlloc(std.heap.page_allocator, file, 0, 4);
    defer std.heap.page_allocator.free(magic);
    if (!std.mem.eql(u8, magic, "CrAU")) return error.InvalidMagic;

    const version = try readU64Be(file, 4);
    if (version != 2) return error.UnsupportedPayloadVersion;

    const manifest_len = try readU64Be(file, 12);
    const sig_len = try readU32Be(file, 20);

    return .{
        .version = version,
        .manifest_len = manifest_len,
        .metadata_signature_len = sig_len,
    };
}

fn readU64Be(file: std.fs.File, off: u64) !u64 {
    var buf: [8]u8 = undefined;
    _ = try file.preadAll(&buf, off);
    return std.mem.readInt(u64, &buf, .big);
}

fn readU32Be(file: std.fs.File, off: u64) !u32 {
    var buf: [4]u8 = undefined;
    _ = try file.preadAll(&buf, off);
    return std.mem.readInt(u32, &buf, .big);
}

fn readAtAlloc(allocator: std.mem.Allocator, file: std.fs.File, off: u64, len_u64: u64) ![]u8 {
    const len = std.math.cast(usize, len_u64) orelse return error.IntegerOverflow;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    _ = try file.preadAll(buf, off);
    return buf;
}

fn sumExtentBytes(ctx: *c.zp_ctx, pidx: usize, oidx: usize, extent_count: usize) usize {
    var total: u64 = 0;
    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        total += c.zp_dst_extent_num_blocks(ctx, pidx, oidx, eidx) * block_size;
    }
    return @intCast(total);
}

fn copyToExtents(
    ctx: *c.zp_ctx,
    pidx: usize,
    oidx: usize,
    extent_count: usize,
    out: std.fs.File,
    data: []const u8,
) !void {
    var read_off: usize = 0;
    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        const extent_off = c.zp_dst_extent_start_block(ctx, pidx, oidx, eidx) * block_size;
        const extent_len_u64 = c.zp_dst_extent_num_blocks(ctx, pidx, oidx, eidx) * block_size;
        const extent_len: usize = @intCast(extent_len_u64);
        if (read_off + extent_len > data.len) return error.UnexpectedBytesWritten;
        try out.pwriteAll(data[read_off .. read_off + extent_len], extent_off);
        read_off += extent_len;
    }
    if (read_off != data.len) return error.UnexpectedBytesWritten;
}

fn writeZeroToExtents(
    allocator: std.mem.Allocator,
    ctx: *c.zp_ctx,
    pidx: usize,
    oidx: usize,
    extent_count: usize,
    out: std.fs.File,
) !void {
    const chunk = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(chunk);
    @memset(chunk, 0);

    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        const extent_off = c.zp_dst_extent_start_block(ctx, pidx, oidx, eidx) * block_size;
        var remaining: u64 = c.zp_dst_extent_num_blocks(ctx, pidx, oidx, eidx) * block_size;
        var write_off: u64 = 0;
        while (remaining > 0) {
            const n: usize = @intCast(@min(remaining, chunk.len));
            try out.pwriteAll(chunk[0..n], extent_off + write_off);
            remaining -= n;
            write_off += n;
        }
    }
}

fn decompressBz2(allocator: std.mem.Allocator, compressed: []const u8, expected_size: usize) ![]u8 {
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

fn decompressZstd(allocator: std.mem.Allocator, compressed: []const u8, expected_size: usize) ![]u8 {
    const out = try allocator.alloc(u8, expected_size);
    errdefer allocator.free(out);

    const n = c.ZSTD_decompress(out.ptr, out.len, compressed.ptr, compressed.len);
    if (c.ZSTD_isError(n) != 0) return error.ZstdDecompressFailed;
    if (n != expected_size) return error.DecompressedSizeMismatch;
    return out;
}

fn decompressXz(allocator: std.mem.Allocator, compressed: []const u8, expected_size: usize) ![]u8 {
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

fn containsPartition(parts: []const []const u8, name: []const u8) bool {
    for (parts) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}
