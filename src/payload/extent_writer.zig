const std = @import("std");
const errors = @import("../errors.zig");
const proto = @import("../proto/chromeos_update_engine.pb.zig");

pub const block_size: u64 = 4096;
pub const Error = errors.AppError;

pub const Extent = struct {
    start_block: u64,
    num_blocks: u64,
    offset_bytes: u64,
    length_bytes: u64,
};

pub fn bytesForBlocks(num_blocks: u64) Error!u64 {
    return std.math.mul(u64, num_blocks, block_size) catch return error.IntegerOverflow;
}

pub fn sumExtentBytes(extents: []const proto.Extent) Error!usize {
    var total: u64 = 0;
    for (extents) |extent| {
        const extent_bytes = try bytesForBlocks(extent.num_blocks orelse 0);
        total = std.math.add(u64, total, extent_bytes) catch return error.IntegerOverflow;
    }
    return std.math.cast(usize, total) orelse return error.IntegerOverflow;
}

pub const ExtentCursor = struct {
    extents: []const Extent,
    fw: *std.Io.File.Writer,
    extent_idx: usize = 0,
    extent_written: u64 = 0,
    total_written: u64 = 0,
    expected_total: u64 = 0,

    pub fn init(
        extents: []const Extent,
        expected_total: u64,
        fw: *std.Io.File.Writer,
    ) ExtentCursor {
        return .{
            .extents = extents,
            .fw = fw,
            .expected_total = expected_total,
        };
    }

    fn currentExtentLen(self: ExtentCursor) u64 {
        return self.extents[self.extent_idx].length_bytes;
    }

    pub fn writeAll(self: *ExtentCursor, data: []const u8) Error!void {
        var pos: usize = 0;
        while (pos < data.len) {
            if (self.extent_idx >= self.extents.len) return error.UnexpectedBytesWritten;

            const extent = self.extents[self.extent_idx];
            const extent_len = extent.length_bytes;
            if (self.extent_written >= extent_len) {
                self.extent_idx += 1;
                self.extent_written = 0;
                continue;
            }

            const remain: usize = @intCast(extent_len - self.extent_written);
            const n = @min(remain, data.len - pos);
            const write_off = std.math.add(u64, extent.offset_bytes, self.extent_written) catch return error.IntegerOverflow;
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
        if (self.extent_idx < self.extents.len) {
            var idx = self.extent_idx;
            if (self.extent_written != 0) return error.UnexpectedBytesWritten;
            while (idx < self.extents.len) : (idx += 1) {
                if (self.extents[idx].num_blocks != 0) return error.UnexpectedBytesWritten;
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
    cursor: *ExtentCursor,
    zero_buf: []const u8,
) Error!void {
    var remaining = cursor.expected_total;
    while (remaining > 0) {
        const n: usize = @intCast(@min(remaining, zero_buf.len));
        try cursor.writeAll(zero_buf[0..n]);
        remaining -= n;
    }
}

test "bytesForBlocks detects overflow" {
    const max_ok = std.math.maxInt(u64) / block_size;
    try std.testing.expectEqual(max_ok * block_size, try bytesForBlocks(max_ok));
    try std.testing.expectError(error.IntegerOverflow, bytesForBlocks(max_ok + 1));
}
