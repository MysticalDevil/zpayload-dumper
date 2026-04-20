const std = @import("std");
const errors = @import("../errors.zig");
const upb = @import("../ffi/upb.zig");
const compress = @import("../ffi/compress.zig");
const progress = @import("progress.zig");
const extent_writer = @import("extent_writer.zig");
const extract_plan = @import("extract_plan.zig");

pub const Error = errors.AppError;

/// A single decompress task: one partition, one operation.
const Task = struct {
    partition_index: usize,
    operation_index: usize,
    tmp_path: []const u8,
};

/// Per-partition state tracked by the engine.
const PartitionState = struct {
    job: extract_plan.PartitionJob,
    tmp_dir: []const u8,
    output_path: []const u8,
    completed_ops: std.atomic.Value(usize),
    has_errors: std.atomic.Value(bool),
};

/// Shared state among all worker threads.
const Shared = struct {
    payload_file: std.Io.File,
    io: std.Io,
    plan: *const extract_plan.Plan,
    tasks: []const Task,
    next_task: std.atomic.Value(usize),
    completed_tasks: std.atomic.Value(usize),
    partitions: []PartitionState,
    tracker: *progress.ProgressTracker,
    collector: *progress.ErrorCollector,
    data_offset: u64,
};

/// Run the full extraction pipeline using a global worker pool.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    payload_file: std.Io.File,
    data_offset: u64,
    plan: *const extract_plan.Plan,
    output_dir: []const u8,
    concurrency: usize,
    tracker: *progress.ProgressTracker,
    collector: *progress.ErrorCollector,
) Error!void {
    // --- Phase 1: Prepare directories, pre-allocate output files, build task queue ---
    var tasks = std.array_list.Managed(Task).init(allocator);
    defer tasks.deinit();

    var partitions = try allocator.alloc(PartitionState, plan.jobs.len);
    defer allocator.free(partitions);

    for (plan.jobs, 0..) |job, pidx| {
        // Create temp directory for this partition.
        const tmp_dir = try std.fmt.allocPrint(allocator, "{s}/.zpayload_tmp/{s}", .{ output_dir, job.name });
        errdefer allocator.free(tmp_dir);
        std.Io.Dir.cwd().createDirPath(io, tmp_dir) catch return error.IoFailure;

        // Pre-allocate output file to final size.
        const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.img", .{ output_dir, job.name });
        errdefer allocator.free(output_path);
        {
            var out = std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true }) catch return error.IoFailure;
            errdefer out.close(io);
            out.setLength(io, job.total_output_bytes) catch return error.IoFailure;
            out.close(io);
        }

        partitions[pidx] = .{
            .job = job,
            .tmp_dir = tmp_dir,
            .output_path = output_path,
            .completed_ops = .init(0),
            .has_errors = .init(false),
        };

        // Build tasks for each operation.
        for (0..job.total_operations) |oidx| {
            const tmp_path = try std.fmt.allocPrint(allocator, "{s}/op{d}.tmp", .{ tmp_dir, oidx });
            try tasks.append(.{
                .partition_index = pidx,
                .operation_index = oidx,
                .tmp_path = tmp_path,
            });
        }
    }

    const task_slice = try tasks.toOwnedSlice();
    defer {
        for (task_slice) |t| allocator.free(t.tmp_path);
        allocator.free(task_slice);
    }

    // --- Phase 2: Start worker threads for parallel decompression ---
    const worker_count = @max(concurrency, std.Thread.getCpuCount() catch 4);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var shared = Shared{
        .payload_file = payload_file,
        .io = io,
        .plan = plan,
        .tasks = task_slice,
        .next_task = .init(0),
        .completed_tasks = .init(0),
        .partitions = partitions,
        .tracker = tracker,
        .collector = collector,
        .data_offset = data_offset,
    };

    for (threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, workerMain, .{&shared}) catch return error.IoFailure;
    }

    // Wait for all workers to finish.
    for (threads) |thread| thread.join();

    // Clean up per-partition allocation strings regardless of merge outcome.
    defer for (partitions) |*part| {
        allocator.free(part.tmp_dir);
        allocator.free(part.output_path);
    };

    // --- Phase 3: Merge temp files into final output (main thread does this sequentially) ---
    for (partitions, 0..) |*part, pidx| {
        if (part.has_errors.load(.acquire)) continue;

        // Open output file for writing.
        var out = std.Io.Dir.cwd().openFile(io, part.output_path, .{ .mode = .read_write }) catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "failed to open output for merge {s}: {s}", .{ part.job.name, @errorName(err) });
            collector.addOwned(msg);
            continue;
        };
        defer out.close(io);

        var writer_buf: [64 * 1024]u8 = undefined;
        var file_writer = out.writer(io, &writer_buf);

        for (part.job.operations, 0..) |op, oidx| {
            const tmp_path = try std.fmt.allocPrint(allocator, "{s}/op{d}.tmp", .{ part.tmp_dir, oidx });
            defer allocator.free(tmp_path);

            // Open temp file.
            var tmp_file = std.Io.Dir.cwd().openFile(io, tmp_path, .{ .mode = .read_only }) catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "failed to open temp file for {s} op{d}: {s}", .{ part.job.name, oidx, @errorName(err) });
                collector.addOwned(msg);
                part.has_errors.store(true, .release);
                break;
            };
            defer tmp_file.close(io);

            // Write temp content through ExtentCursor.
            var cursor = extent_writer.ExtentCursor.init(op.extents, op.expected_uncompressed, &file_writer);
            var copy_buf: [64 * 1024]u8 = undefined;
            var read_pos: u64 = 0;
            while (true) {
                const n = tmp_file.readPositionalAll(io, &copy_buf, read_pos) catch |err| {
                    const msg = try std.fmt.allocPrint(allocator, "failed to read temp file for {s} op{d}: {s}", .{ part.job.name, oidx, @errorName(err) });
                    collector.addOwned(msg);
                    part.has_errors.store(true, .release);
                    break;
                };
                if (n == 0) break;
                read_pos += n;
                cursor.writeAll(copy_buf[0..n]) catch |err| {
                    const msg = try std.fmt.allocPrint(allocator, "failed to write merged data for {s} op{d}: {s}", .{ part.job.name, oidx, @errorName(err) });
                    collector.addOwned(msg);
                    part.has_errors.store(true, .release);
                    break;
                };
            }
            cursor.finish() catch |err| {
                const msg = try std.fmt.allocPrint(allocator, "extent mismatch during merge for {s} op{d}: {s}", .{ part.job.name, oidx, @errorName(err) });
                collector.addOwned(msg);
                part.has_errors.store(true, .release);
            };

            // Delete temp file immediately after merging.
            std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
        }

        file_writer.flush() catch |err| {
            const msg = try std.fmt.allocPrint(allocator, "failed to flush output for {s}: {s}", .{ part.job.name, @errorName(err) });
            collector.addOwned(msg);
            part.has_errors.store(true, .release);
        };

        // Remove temp directory if no errors.
        if (!part.has_errors.load(.acquire)) {
            std.Io.Dir.cwd().deleteTree(io, part.tmp_dir) catch {};
        }

        // Mark partition as done in tracker.
        tracker.markDone(pidx);
    }
}

fn workerMain(shared: *Shared) void {
    // Per-worker reusable buffers.
    var compress_in_buf: [compress.chunk_size]u8 = undefined;
    var compress_out_buf: [compress.chunk_size]u8 = undefined;
    var zero_buf: [1024 * 1024]u8 = undefined;
    @memset(&zero_buf, 0);

    while (true) {
        const index = shared.next_task.fetchAdd(1, .monotonic);
        if (index >= shared.tasks.len) break;

        const task = shared.tasks[index];
        const part = &shared.partitions[task.partition_index];
        const op = part.job.operations[task.operation_index];

        // Mark partition as running on first task.
        if (task.operation_index == 0) {
            shared.tracker.markRunning(task.partition_index);
        }

        // Skip if partition already has errors.
        if (part.has_errors.load(.acquire)) {
            _ = part.completed_ops.fetchAdd(1, .release);
            _ = shared.completed_tasks.fetchAdd(1, .release);
            continue;
        }

        // Create temp file and decompress into it.
        var tmp_file = std.Io.Dir.cwd().createFile(shared.io, task.tmp_path, .{ .truncate = true }) catch |err| {
            const msg = std.fmt.allocPrint(std.heap.page_allocator, "failed to create temp file for {s} op{d}: {s}", .{ part.job.name, task.operation_index, @errorName(err) }) catch null;
            if (msg) |m| shared.collector.addOwned(m);
            part.has_errors.store(true, .release);
            _ = part.completed_ops.fetchAdd(1, .release);
            _ = shared.completed_tasks.fetchAdd(1, .release);
            continue;
        };
        defer tmp_file.close(shared.io);

        var tmp_writer_buf: [64 * 1024]u8 = undefined;
        var tmp_writer = tmp_file.writer(shared.io, &tmp_writer_buf);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        switch (op.op_type) {
            .replace => {
                const bytes_written = compress.copyRawToWriter(shared.payload_file, shared.io, op.blob_offset, op.blob_length, &hasher, &tmp_writer.interface, &compress_in_buf) catch |err| {
                    recordError(shared, part, task.operation_index, err);
                    continue;
                };
                std.debug.assert(bytes_written <= op.blob_length);
            },
            .replace_xz => {
                const bytes_written = compress.decompressXzToWriter(shared.payload_file, shared.io, op.blob_offset, op.blob_length, &hasher, &tmp_writer.interface, &compress_in_buf, &compress_out_buf) catch |err| {
                    recordError(shared, part, task.operation_index, err);
                    continue;
                };
                std.debug.assert(bytes_written <= op.expected_uncompressed);
            },
            .replace_bz => {
                const bytes_written = compress.decompressBz2ToWriter(shared.payload_file, shared.io, op.blob_offset, op.blob_length, &hasher, &tmp_writer.interface, &compress_in_buf, &compress_out_buf) catch |err| {
                    recordError(shared, part, task.operation_index, err);
                    continue;
                };
                std.debug.assert(bytes_written <= op.expected_uncompressed);
            },
            .zstd => {
                const bytes_written = compress.decompressZstdToWriter(shared.payload_file, shared.io, op.blob_offset, op.blob_length, &hasher, &tmp_writer.interface, &compress_in_buf, &compress_out_buf) catch |err| {
                    recordError(shared, part, task.operation_index, err);
                    continue;
                };
                std.debug.assert(bytes_written <= op.expected_uncompressed);
            },
            .zero => {
                var remaining = op.blob_length;
                var position = op.blob_offset;
                while (remaining > 0) {
                    const chunk_len: usize = @intCast(@min(remaining, zero_buf.len));
                    const read_count = shared.payload_file.readPositionalAll(shared.io, zero_buf[0..chunk_len], position) catch |err| {
                        recordError(shared, part, task.operation_index, err);
                        break;
                    };
                    std.debug.assert(read_count == chunk_len);
                    hasher.update(zero_buf[0..chunk_len]);
                    remaining -= chunk_len;
                    position += chunk_len;
                }
                if (part.has_errors.load(.acquire)) continue;
                @memset(&zero_buf, 0);
                var cursor = extent_writer.ExtentCursor.init(op.extents, op.expected_uncompressed, &tmp_writer);
                extent_writer.writeZeroToExtents(&cursor, &zero_buf) catch |err| {
                    recordError(shared, part, task.operation_index, err);
                    continue;
                };
            },
            else => {
                recordError(shared, part, task.operation_index, error.UnhandledOperationType);
                continue;
            },
        }

        // Flush temp writer.
        tmp_writer.flush() catch |err| {
            recordError(shared, part, task.operation_index, err);
            continue;
        };

        // Verify SHA-256.
        if (op.sha256) |expected| {
            var hash: [32]u8 = undefined;
            hasher.final(&hash);
            if (!std.mem.eql(u8, expected, hash[0..])) {
                recordError(shared, part, task.operation_index, error.ChecksumMismatch);
                continue;
            }
        }

        // Update progress.
        const completed = part.completed_ops.fetchAdd(1, .release) + 1;
        shared.tracker.updateOps(task.partition_index, completed);
        _ = shared.completed_tasks.fetchAdd(1, .release);
    }
}

fn recordError(shared: *Shared, part: *PartitionState, operation_index: usize, err: anyerror) void {
    const msg = std.fmt.allocPrint(std.heap.page_allocator, "failed to decompress {s} op{d}: {s}", .{
        part.job.name,
        operation_index,
        @errorName(err),
    }) catch null;
    if (msg) |m| shared.collector.addOwned(m);
    part.has_errors.store(true, .release);
    _ = part.completed_ops.fetchAdd(1, .release);
    _ = shared.completed_tasks.fetchAdd(1, .release);
}
