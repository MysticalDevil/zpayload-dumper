const std = @import("std");
const errors = @import("../errors.zig");
const proto = @import("../proto/chromeos_update_engine.pb.zig");
const extent_writer = @import("extent_writer.zig");

pub const Extent = extent_writer.Extent;
pub const Error = errors.AppError;

pub const Operation = struct {
    op_type: proto.InstallOperation.Type,
    blob_offset: u64,
    blob_length: u64,
    expected_uncompressed: u64,
    extents: []const Extent,
    src_extents: []const Extent,
    src_length: u64,
    sha256: ?[]const u8,
    src_sha256: ?[]const u8,
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
    manifest: *const proto.DeltaArchiveManifest,
    data_offset: u64,
    selected: []const []const u8,
) Error!Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var jobs = std.array_list.Managed(PartitionJob).init(aa);

    for (manifest.partitions.items, 0..) |partition, partition_index| {
        const name_raw = partition.partition_name;
        try validatePartitionName(name_raw);
        if (selected.len != 0 and !containsPartition(selected, name_raw)) continue;

        const name = try aa.dupe(u8, name_raw);
        const op_count = partition.operations.items.len;
        var operations = try aa.alloc(Operation, op_count);

        var total_output_bytes: u64 = 0;

        for (partition.operations.items, 0..) |op, operation_index| {
            if (op.dst_extents.items.len == 0) return error.InvalidDstExtents;

            const blob_off_u64 = op.data_offset orelse 0;
            const blob_len_u64 = op.data_length orelse 0;
            const blob_abs = std.math.add(u64, data_offset, blob_off_u64) catch return error.IntegerOverflow;
            const expected_uncompressed = try extent_writer.sumExtentBytes(op.dst_extents.items);
            const op_type = op.type;

            // Convert proto dst extents to internal Extent format, merging adjacent ones
            const extent_count = op.dst_extents.items.len;
            var extents = try aa.alloc(Extent, extent_count);
            var merged_count: usize = 0;
            for (op.dst_extents.items) |dst_extent| {
                const start_block = dst_extent.start_block orelse 0;
                const num_blocks = dst_extent.num_blocks orelse 0;
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

            // Convert proto src extents
            const src_extent_count = op.src_extents.items.len;
            var src_extents = try aa.alloc(Extent, @max(src_extent_count, 1));
            var src_merged_count: usize = 0;
            for (op.src_extents.items) |src_extent| {
                const start_block = src_extent.start_block orelse 0;
                const num_blocks = src_extent.num_blocks orelse 0;
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
            const src_length = op.src_length orelse 0;

            total_output_bytes = std.math.add(u64, total_output_bytes, expected_uncompressed) catch return error.IntegerOverflow;

            const sha256: ?[]const u8 = if (op.data_sha256_hash) |s| try aa.dupe(u8, s) else null;
            const src_sha256: ?[]const u8 = if (op.src_sha256_hash) |s| try aa.dupe(u8, s) else null;

            operations[operation_index] = .{
                .op_type = op_type,
                .blob_offset = blob_abs,
                .blob_length = blob_len_u64,
                .expected_uncompressed = expected_uncompressed,
                .extents = extents,
                .src_extents = src_extents,
                .src_length = src_length,
                .sha256 = sha256,
                .src_sha256 = src_sha256,
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

fn validatePartitionName(name: []const u8) Error!void {
    if (name.len == 0) return error.InvalidPartitionName;
    if (std.fs.path.isAbsolute(name)) return error.InvalidPartitionName;

    var components = std.mem.splitScalar(u8, name, '/');
    while (components.next()) |component| {
        if (component.len == 0) return error.InvalidPartitionName;
        if (std.mem.eql(u8, component, ".") or std.mem.eql(u8, component, "..")) {
            return error.InvalidPartitionName;
        }
    }

    if (std.mem.indexOfScalar(u8, name, '\\') != null) return error.InvalidPartitionName;
}

test "validatePartitionName accepts normal Android partition names" {
    try validatePartitionName("boot");
    try validatePartitionName("vendor_boot");
    try validatePartitionName("system_ext");
}

test "validatePartitionName rejects traversal and path separators" {
    try std.testing.expectError(error.InvalidPartitionName, validatePartitionName("../boot"));
    try std.testing.expectError(error.InvalidPartitionName, validatePartitionName("/boot"));
    try std.testing.expectError(error.InvalidPartitionName, validatePartitionName("vendor/boot"));
    try std.testing.expectError(error.InvalidPartitionName, validatePartitionName("vendor\\boot"));
    try std.testing.expectError(error.InvalidPartitionName, validatePartitionName(".."));
}
