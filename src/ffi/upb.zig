const std = @import("std");
const errors = @import("../errors.zig");

const c = @cImport({
    @cInclude("upb_wrap.h");
});

pub const Error = errors.AppError;

pub const OperationType = enum(i32) {
    replace = 0,
    replace_bz = 1,
    zero = 6,
    replace_xz = 8,
    zstd = 14,
    _,
};

pub const Context = struct {
    raw: *c.zp_ctx,

    pub fn init(manifest: []const u8, signature: []const u8) Error!Context {
        const raw = c.zp_ctx_new(manifest.ptr, manifest.len, signature.ptr, signature.len) orelse {
            return error.DecodeFailed;
        };
        return .{ .raw = raw };
    }

    pub fn deinit(self: *Context) void {
        c.zp_ctx_free(self.raw);
        self.* = undefined;
    }

    pub fn partitionCount(self: Context) usize {
        return c.zp_partition_count(self.raw);
    }

    pub fn partitionName(self: Context, partition_index: usize) ?[]const u8 {
        var n: usize = 0;
        const p = c.zp_partition_name(self.raw, partition_index, &n);
        return sliceFromPtrLen(p, n);
    }

    pub fn partitionSize(self: Context, partition_index: usize) u64 {
        return c.zp_partition_size(self.raw, partition_index);
    }

    pub fn operationCount(self: Context, partition_index: usize) usize {
        return c.zp_operation_count(self.raw, partition_index);
    }

    pub fn operationType(self: Context, partition_index: usize, operation_index: usize) ?OperationType {
        const raw_type = c.zp_operation_type(self.raw, partition_index, operation_index);
        if (raw_type < 0) return null;
        return @enumFromInt(raw_type);
    }

    pub fn operationDataOffset(self: Context, partition_index: usize, operation_index: usize) u64 {
        return c.zp_operation_data_offset(self.raw, partition_index, operation_index);
    }

    pub fn operationDataLength(self: Context, partition_index: usize, operation_index: usize) u64 {
        return c.zp_operation_data_length(self.raw, partition_index, operation_index);
    }

    pub fn operationSha256(self: Context, partition_index: usize, operation_index: usize) ?[]const u8 {
        var n: usize = 0;
        const p = c.zp_operation_data_sha256(self.raw, partition_index, operation_index, &n);
        return sliceFromPtrLen(p, n);
    }

    pub fn dstExtentCount(self: Context, partition_index: usize, operation_index: usize) usize {
        return c.zp_dst_extent_count(self.raw, partition_index, operation_index);
    }

    pub fn dstExtentStartBlock(self: Context, partition_index: usize, operation_index: usize, extent_index: usize) u64 {
        return c.zp_dst_extent_start_block(self.raw, partition_index, operation_index, extent_index);
    }

    pub fn dstExtentNumBlocks(self: Context, partition_index: usize, operation_index: usize, extent_index: usize) u64 {
        return c.zp_dst_extent_num_blocks(self.raw, partition_index, operation_index, extent_index);
    }
};

fn sliceFromPtrLen(ptr: ?*const u8, len: usize) ?[]const u8 {
    if (ptr == null or len == 0) return null;
    const p: [*]const u8 = @ptrCast(ptr.?);
    return p[0..len];
}
