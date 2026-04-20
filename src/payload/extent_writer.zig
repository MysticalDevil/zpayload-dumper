const std = @import("std");
const errors = @import("../errors.zig");
const upb = @import("../ffi/upb.zig");

pub const block_size: u64 = 4096;
pub const Error = errors.AppError;

pub fn bytesForBlocks(num_blocks: u64) Error!u64 {
    return std.math.mul(u64, num_blocks, block_size) catch return error.IntegerOverflow;
}

pub fn sumExtentBytes(ctx: upb.Context, pidx: usize, oidx: usize, extent_count: usize) Error!usize {
    var total: u64 = 0;
    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        const extent_bytes = try bytesForBlocks(ctx.dstExtentNumBlocks(pidx, oidx, eidx));
        total = std.math.add(u64, total, extent_bytes) catch return error.IntegerOverflow;
    }
    return std.math.cast(usize, total) orelse return error.IntegerOverflow;
}

pub const ExtentCursor = struct {
    ctx: upb.Context,
    pidx: usize,
    oidx: usize,
    extent_count: usize,
    fw: *std.Io.File.Writer,
    extent_idx: usize = 0,
    extent_written: u64 = 0,
    total_written: u64 = 0,
    expected_total: u64 = 0,

    pub fn init(
        ctx: upb.Context,
        pidx: usize,
        oidx: usize,
        extent_count: usize,
        expected_total: usize,
        fw: *std.Io.File.Writer,
    ) ExtentCursor {
        return .{
            .ctx = ctx,
            .pidx = pidx,
            .oidx = oidx,
            .extent_count = extent_count,
            .fw = fw,
            .expected_total = @intCast(expected_total),
        };
    }

    fn currentExtentLen(self: ExtentCursor) Error!u64 {
        return bytesForBlocks(self.ctx.dstExtentNumBlocks(self.pidx, self.oidx, self.extent_idx));
    }

    pub fn writeAll(self: *ExtentCursor, data: []const u8) Error!void {
        var pos: usize = 0;
        while (pos < data.len) {
            if (self.extent_idx >= self.extent_count) return error.UnexpectedBytesWritten;

            const extent_off = try bytesForBlocks(self.ctx.dstExtentStartBlock(self.pidx, self.oidx, self.extent_idx));
            const extent_len = try self.currentExtentLen();
            if (self.extent_written >= extent_len) {
                self.extent_idx += 1;
                self.extent_written = 0;
                continue;
            }

            const remain: usize = @intCast(extent_len - self.extent_written);
            const n = @min(remain, data.len - pos);
            const write_off = std.math.add(u64, extent_off, self.extent_written) catch return error.IntegerOverflow;
            self.fw.seekTo(write_off) catch return error.IoFailure;
            self.fw.interface.writeAll(data[pos .. pos + n]) catch return error.IoFailure;
            pos += n;
            self.extent_written += n;
            self.total_written += n;
            if (self.extent_written == extent_len) {
                self.extent_idx += 1;
                self.extent_written = 0;
            }
        }
    }

    pub fn finish(self: *ExtentCursor) Error!void {
        if (self.total_written != self.expected_total) return error.UnexpectedBytesWritten;
        if (self.extent_idx < self.extent_count) {
            var idx = self.extent_idx;
            if (self.extent_written != 0) return error.UnexpectedBytesWritten;
            while (idx < self.extent_count) : (idx += 1) {
                if (self.ctx.dstExtentNumBlocks(self.pidx, self.oidx, idx) != 0) return error.UnexpectedBytesWritten;
            }
        }
    }

    pub fn writer(self: *ExtentCursor) WriterAdapter {
        return WriterAdapter.init(self);
    }
};

pub const WriterAdapter = struct {
    cursor: *ExtentCursor,
    writer: std.Io.Writer,

    pub fn init(cursor: *ExtentCursor) WriterAdapter {
        return .{
            .cursor = cursor,
            .writer = .{
                .buffer = &.{},
                .vtable = &.{ .drain = drain },
            },
        };
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *WriterAdapter = @alignCast(@fieldParentPtr("writer", writer));

        const buffered = writer.buffered();
        if (buffered.len != 0) {
            self.cursor.writeAll(buffered) catch return error.WriteFailed;
            writer.end = 0;
        }

        var total_written: usize = 0;
        for (data[0 .. data.len - 1]) |slice| {
            self.cursor.writeAll(slice) catch return error.WriteFailed;
            total_written += slice.len;
        }

        const pattern = data[data.len - 1];
        if (pattern.len == 0 or splat == 0) return total_written;

        var remaining = splat;
        while (remaining > 0) : (remaining -= 1) {
            self.cursor.writeAll(pattern) catch return error.WriteFailed;
            total_written += pattern.len;
        }

        return total_written;
    }
};

pub fn writeZeroToExtents(
    allocator: std.mem.Allocator,
    cursor: *ExtentCursor,
) Error!void {
    const chunk = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(chunk);
    @memset(chunk, 0);

    var remaining = cursor.expected_total;
    while (remaining > 0) {
        const n: usize = @intCast(@min(remaining, chunk.len));
        try cursor.writeAll(chunk[0..n]);
        remaining -= n;
    }
}

test "bytesForBlocks detects overflow" {
    const max_ok = std.math.maxInt(u64) / block_size;
    try std.testing.expectEqual(max_ok * block_size, try bytesForBlocks(max_ok));
    try std.testing.expectError(error.IntegerOverflow, bytesForBlocks(max_ok + 1));
}
