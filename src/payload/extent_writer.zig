const std = @import("std");
const errors = @import("../errors.zig");
const upb = @import("../ffi/upb.zig");

pub const block_size: u64 = 4096;
pub const Error = errors.PayloadError || errors.SystemError;

pub fn sumExtentBytes(ctx: upb.Context, pidx: usize, oidx: usize, extent_count: usize) usize {
    var total: u64 = 0;
    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        total += ctx.dstExtentNumBlocks(pidx, oidx, eidx) * block_size;
    }
    return @intCast(total);
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

    fn currentExtentLen(self: ExtentCursor) u64 {
        return self.ctx.dstExtentNumBlocks(self.pidx, self.oidx, self.extent_idx) * block_size;
    }

    pub fn writeAll(self: *ExtentCursor, data: []const u8) Error!void {
        var pos: usize = 0;
        while (pos < data.len) {
            if (self.extent_idx >= self.extent_count) return error.UnexpectedBytesWritten;

            const extent_off = self.ctx.dstExtentStartBlock(self.pidx, self.oidx, self.extent_idx) * block_size;
            const extent_len = self.currentExtentLen();
            if (self.extent_written >= extent_len) {
                self.extent_idx += 1;
                self.extent_written = 0;
                continue;
            }

            const remain: usize = @intCast(extent_len - self.extent_written);
            const n = @min(remain, data.len - pos);
            self.fw.seekTo(extent_off + self.extent_written) catch return error.IoFailure;
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
