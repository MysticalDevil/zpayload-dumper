const std = @import("std");
const upb = @import("ffi/upb.zig");
const compress = @import("ffi/compress.zig");

pub const block_size: u64 = 4096;

pub const Payload = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,
    header: Header = .{},
    metadata_size: u64 = 0,
    data_offset: u64 = 0,
    ctx: ?upb.Context = null,

    pub fn open(allocator: std.mem.Allocator, filename: []const u8) !Payload {
        const file = try std.fs.cwd().openFile(filename, .{});
        return .{ .allocator = allocator, .file = file };
    }

    pub fn deinit(self: *Payload) void {
        if (self.ctx) |*ctx| ctx.deinit();
        self.file.close();
    }

    pub fn init(self: *Payload) !void {
        self.header = try readHeader(self.file);

        const manifest_buf = try readAtAlloc(self.allocator, self.file, 24, self.header.manifest_len);
        defer self.allocator.free(manifest_buf);
        const signature_off = 24 + self.header.manifest_len;
        const signature_buf = try readAtAlloc(self.allocator, self.file, signature_off, self.header.metadata_signature_len);
        defer self.allocator.free(signature_buf);

        self.ctx = try upb.Context.init(manifest_buf, signature_buf);
        self.metadata_size = 24 + self.header.manifest_len;
        self.data_offset = self.metadata_size + self.header.metadata_signature_len;
    }

    pub fn printPartitionList(self: *Payload, w: *std.Io.Writer) !void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        try w.writeAll("Found partitions:\n");
        const n = ctx.partitionCount();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const name = ctx.partitionName(i) orelse continue;
            try w.print("  {s} ({d} bytes)\n", .{ name, ctx.partitionSize(i) });
        }
    }

    pub fn partitionCount(self: *Payload) !usize {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        return ctx.partitionCount();
    }

    pub fn extractAll(self: *Payload, output_dir: []const u8) !void {
        return self.extractSelected(output_dir, &.{});
    }

    pub fn extractSelected(self: *Payload, output_dir: []const u8, selected: []const []const u8) !void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        const n = ctx.partitionCount();
        var pidx: usize = 0;
        while (pidx < n) : (pidx += 1) {
            const name = ctx.partitionName(pidx) orelse continue;
            if (selected.len != 0 and !containsPartition(selected, name)) continue;

            const out_path = try std.fmt.allocPrint(self.allocator, "{s}/{s}.img", .{ output_dir, name });
            defer self.allocator.free(out_path);

            var out = try std.fs.cwd().createFile(out_path, .{ .truncate = true });
            defer out.close();
            try self.extractPartition(ctx, pidx, out);
        }
    }

    fn extractPartition(self: *Payload, ctx: upb.Context, pidx: usize, out: std.fs.File) !void {
        const op_count = ctx.operationCount(pidx);
        var oidx: usize = 0;
        while (oidx < op_count) : (oidx += 1) {
            const extent_count = ctx.dstExtentCount(pidx, oidx);
            if (extent_count == 0) return error.InvalidDstExtents;

            const blob_len_u64 = ctx.operationDataLength(pidx, oidx);
            const blob_off_u64 = ctx.operationDataOffset(pidx, oidx);
            const blob_abs = self.data_offset + blob_off_u64;
            const blob = try readAtAlloc(self.allocator, self.file, blob_abs, blob_len_u64);
            defer self.allocator.free(blob);

            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(blob, &hash, .{});

            const expected_uncompressed = sumExtentBytes(ctx, pidx, oidx, extent_count);
            const op_type = ctx.operationType(pidx, oidx) orelse return error.UnhandledOperationType;

            switch (op_type) {
                .replace => {
                    if (blob.len != expected_uncompressed) return error.UnexpectedBytesWritten;
                    try copyToExtents(ctx, pidx, oidx, extent_count, out, blob);
                },
                .replace_xz => {
                    const out_buf = try compress.decompressXz(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, out, out_buf);
                },
                .replace_bz => {
                    const out_buf = try compress.decompressBz2(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, out, out_buf);
                },
                .zstd => {
                    const out_buf = try compress.decompressZstd(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, out, out_buf);
                },
                .zero => {
                    try writeZeroToExtents(self.allocator, ctx, pidx, oidx, extent_count, out);
                },
                else => return error.UnhandledOperationType,
            }

            if (ctx.operationSha256(pidx, oidx)) |expected| {
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

fn sumExtentBytes(ctx: upb.Context, pidx: usize, oidx: usize, extent_count: usize) usize {
    var total: u64 = 0;
    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        total += ctx.dstExtentNumBlocks(pidx, oidx, eidx) * block_size;
    }
    return @intCast(total);
}

fn copyToExtents(
    ctx: upb.Context,
    pidx: usize,
    oidx: usize,
    extent_count: usize,
    out: std.fs.File,
    data: []const u8,
) !void {
    var read_off: usize = 0;
    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        const extent_off = ctx.dstExtentStartBlock(pidx, oidx, eidx) * block_size;
        const extent_len_u64 = ctx.dstExtentNumBlocks(pidx, oidx, eidx) * block_size;
        const extent_len: usize = @intCast(extent_len_u64);
        if (read_off + extent_len > data.len) return error.UnexpectedBytesWritten;
        try out.pwriteAll(data[read_off .. read_off + extent_len], extent_off);
        read_off += extent_len;
    }
    if (read_off != data.len) return error.UnexpectedBytesWritten;
}

fn writeZeroToExtents(
    allocator: std.mem.Allocator,
    ctx: upb.Context,
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
        const extent_off = ctx.dstExtentStartBlock(pidx, oidx, eidx) * block_size;
        var remaining: u64 = ctx.dstExtentNumBlocks(pidx, oidx, eidx) * block_size;
        var write_off: u64 = 0;
        while (remaining > 0) {
            const n: usize = @intCast(@min(remaining, chunk.len));
            try out.pwriteAll(chunk[0..n], extent_off + write_off);
            remaining -= n;
            write_off += n;
        }
    }
}

fn containsPartition(parts: []const []const u8, name: []const u8) bool {
    for (parts) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}
