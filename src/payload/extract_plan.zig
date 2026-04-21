const std = @import("std");
const errors = @import("../errors.zig");
const upb = @import("../ffi/upb.zig");
const extent_writer = @import("extent_writer.zig");

pub const Extent = extent_writer.Extent;
pub const Error = errors.AppError;

pub const Operation = struct {
    op_type: upb.OperationType,
    blob_offset: u64,
    blob_length: u64,
    expected_uncompressed: u64,
    extents: []const Extent,
    src_extents: []const Extent,
    src_length: u64,
    sha256: ?[]const u8,
};

pub const PartitionJob = struct {
    pidx: usize,
    name: []const u8,
    operations: []const Operation,
    total_output_bytes: u64,
    total_operations: usize,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    jobs: []PartitionJob,

    pub fn deinit(self: *Plan) void {
        self.arena.deinit();
    }
};

pub fn buildPlan(
    allocator: std.mem.Allocator,
    ctx: upb.Context,
    data_offset: u64,
    selected: []const []const u8,
) Error!Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    const part_count = ctx.partitionCount();
    var jobs = std.array_list.Managed(PartitionJob).init(aa);

    var partition_index: usize = 0;
    while (partition_index < part_count) : (partition_index += 1) {
        const name_raw = ctx.partitionName(partition_index) orelse continue;
        if (selected.len != 0 and !containsPartition(selected, name_raw)) continue;

        const name = try aa.dupe(u8, name_raw);
        const op_count = ctx.operationCount(partition_index);
        var operations = try aa.alloc(Operation, op_count);

        var total_output_bytes: u64 = 0;
        var operation_index: usize = 0;
        while (operation_index < op_count) : (operation_index += 1) {
            const extent_count = ctx.dstExtentCount(partition_index, operation_index);
            if (extent_count == 0) return error.InvalidDstExtents;

            const blob_len_u64 = ctx.operationDataLength(partition_index, operation_index);
            const blob_off_u64 = ctx.operationDataOffset(partition_index, operation_index);
            const blob_abs = std.math.add(u64, data_offset, blob_off_u64) catch return error.IntegerOverflow;
            const expected_uncompressed = try extent_writer.sumExtentBytes(ctx, partition_index, operation_index, extent_count);
            const op_type = ctx.operationType(partition_index, operation_index) orelse return error.UnhandledOperationType;

            var extents = try aa.alloc(Extent, extent_count);
            var merged_count: usize = 0;
            var extent_idx: usize = 0;
            while (extent_idx < extent_count) : (extent_idx += 1) {
                const start_block = ctx.dstExtentStartBlock(partition_index, operation_index, extent_idx);
                const num_blocks = ctx.dstExtentNumBlocks(partition_index, operation_index, extent_idx);
                if (num_blocks == 0) continue;
                const offset_bytes = try extent_writer.bytesForBlocks(start_block);
                const length_bytes = try extent_writer.bytesForBlocks(num_blocks);
                if (merged_count > 0 and offset_bytes == extents[merged_count - 1].offset_bytes + extents[merged_count - 1].length_bytes) {
                    extents[merged_count - 1].num_blocks += num_blocks;
                    extents[merged_count - 1].length_bytes += length_bytes;
                } else {
                    extents[merged_count] = .{
                        .start_block = start_block,
                        .num_blocks = num_blocks,
                        .offset_bytes = offset_bytes,
                        .length_bytes = length_bytes,
                    };
                    merged_count += 1;
                }
            }
            if (merged_count < extent_count) {
                const shrunk = try aa.alloc(Extent, merged_count);
                @memcpy(shrunk, extents[0..merged_count]);
                extents = shrunk;
            }

            // Build src_extents (for delta operations like SOURCE_COPY, SOURCE_BSDIFF)
            const src_extent_count = ctx.srcExtentCount(partition_index, operation_index);
            var src_extents = try aa.alloc(Extent, @max(src_extent_count, 1));
            var src_merged_count: usize = 0;
            var src_extent_idx: usize = 0;
            while (src_extent_idx < src_extent_count) : (src_extent_idx += 1) {
                const start_block = ctx.srcExtentStartBlock(partition_index, operation_index, src_extent_idx);
                const num_blocks = ctx.srcExtentNumBlocks(partition_index, operation_index, src_extent_idx);
                if (num_blocks == 0) continue;
                const offset_bytes = try extent_writer.bytesForBlocks(start_block);
                const length_bytes = try extent_writer.bytesForBlocks(num_blocks);
                if (src_merged_count > 0 and offset_bytes == src_extents[src_merged_count - 1].offset_bytes + src_extents[src_merged_count - 1].length_bytes) {
                    src_extents[src_merged_count - 1].num_blocks += num_blocks;
                    src_extents[src_merged_count - 1].length_bytes += length_bytes;
                } else {
                    src_extents[src_merged_count] = .{
                        .start_block = start_block,
                        .num_blocks = num_blocks,
                        .offset_bytes = offset_bytes,
                        .length_bytes = length_bytes,
                    };
                    src_merged_count += 1;
                }
            }
            if (src_merged_count < src_extent_count) {
                const shrunk = try aa.alloc(Extent, src_merged_count);
                @memcpy(shrunk, src_extents[0..src_merged_count]);
                src_extents = shrunk;
            } else if (src_extent_count == 0) {
                src_extents = src_extents[0..0];
            }
            const src_length = ctx.srcLength(partition_index, operation_index);

            total_output_bytes = std.math.add(u64, total_output_bytes, expected_uncompressed) catch return error.IntegerOverflow;

            const sha256_raw = ctx.operationSha256(partition_index, operation_index);
            const sha256: ?[]const u8 = if (sha256_raw) |s| try aa.dupe(u8, s) else null;

            operations[operation_index] = .{
                .op_type = op_type,
                .blob_offset = blob_abs,
                .blob_length = blob_len_u64,
                .expected_uncompressed = expected_uncompressed,
                .extents = extents,
                .src_extents = src_extents,
                .src_length = src_length,
                .sha256 = sha256,
            };
        }

        try jobs.append(.{
            .pidx = partition_index,
            .name = name,
            .operations = operations,
            .total_output_bytes = total_output_bytes,
            .total_operations = op_count,
        });
    }

    return .{
        .arena = arena,
        .jobs = try jobs.toOwnedSlice(),
    };
}

fn containsPartition(parts: []const []const u8, name: []const u8) bool {
    for (parts) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}
