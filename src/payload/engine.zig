const std = @import("std");
const errors = @import("../errors.zig");
const upb = @import("../ffi/upb.zig");
const compress = @import("../compress/root.zig");
const progress = @import("progress.zig");
const extent_writer = @import("extent_writer.zig");
const extract_plan = @import("extract_plan.zig");
const bsdiff = @import("bsdiff.zig");

pub const Error = errors.AppError;

// ---------------------------------------------------------------------------
// Disk space check via statvfs
// ---------------------------------------------------------------------------

const StatVfs = extern struct {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: u64,
    f_flag: u64,
    f_namemax: u64,
    __f_spare: [6]c_int,
};

extern "c" fn statvfs(path: [*:0]const u8, buf: *StatVfs) c_int;

fn getAvailableBytes(path: []const u8) Error!u64 {
    var path_buf: [4096]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.IoFailure;
    var buf: StatVfs = undefined;
    if (statvfs(path_z.ptr, &buf) != 0) return error.IoFailure;
    return buf.f_bavail * buf.f_frsize;
}

fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const kb: u64 = 1024;
    const mb: u64 = 1024 * 1024;
    const gb: u64 = 1024 * 1024 * 1024;
    if (bytes >= gb) {
        return std.fmt.bufPrint(buf, "{d}.{d:0>2} GiB", .{ bytes / gb, (bytes % gb) * 100 / gb }) catch "unknown";
    }
    if (bytes >= mb) {
        return std.fmt.bufPrint(buf, "{d}.{d:0>2} MiB", .{ bytes / mb, (bytes % mb) * 100 / mb }) catch "unknown";
    }
    if (bytes >= kb) {
        return std.fmt.bufPrint(buf, "{d} KiB", .{bytes / kb}) catch "unknown";
    }
    return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "unknown";
}

// ---------------------------------------------------------------------------
// ArrayList writer adapter for std.Io.Writer
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Core types
// ---------------------------------------------------------------------------

const Task = struct {
    partition_index: usize,
    operation_index: usize,
};

const PendingMap = std.AutoHashMapUnmanaged(usize, PendingChunk);

const PendingData = union(enum) {
    memory: []u8,
    tmp_file: []const u8,
};

const PendingChunk = struct {
    op_index: usize,
    data: PendingData,
};

const PartitionWriteState = struct {
    job: extract_plan.PartitionJob,
    output_path: []const u8,
    output_file: std.Io.File,
    next_expected_op: std.atomic.Value(usize),
    pending: PendingMap,
    pending_mutex: std.Io.Mutex,
    completed_ops: std.atomic.Value(usize),
    has_errors: std.atomic.Value(bool),
    next_enqueued_op: usize,
};

const TaskQueue = struct {
    tasks: []Task,
    head: usize = 0,
    tail: usize = 0,
    len: usize = 0,
    closed: bool = false,
    mutex: std.Io.Mutex = .init,
    semaphore: std.Io.Semaphore = .{},

    fn push(self: *TaskQueue, io: std.Io, task: Task) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        std.debug.assert(!self.closed);
        std.debug.assert(self.len < self.tasks.len);
        self.tasks[self.tail] = task;
        self.tail = (self.tail + 1) % self.tasks.len;
        self.len += 1;
        self.semaphore.post(io);
    }

    fn pop(self: *TaskQueue, io: std.Io) ?Task {
        self.semaphore.waitUncancelable(io);
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        if (self.len == 0) {
            std.debug.assert(self.closed);
            return null;
        }

        const task = self.tasks[self.head];
        self.head = (self.head + 1) % self.tasks.len;
        self.len -= 1;
        return task;
    }

    fn close(self: *TaskQueue, io: std.Io, worker_count: usize) void {
        self.mutex.lockUncancelable(io);
        const already_closed = self.closed;
        self.closed = true;
        self.mutex.unlock(io);

        if (already_closed) return;
        for (0..worker_count) |_| self.semaphore.post(io);
    }
};

const MemoryBudget = struct {
    remaining: std.atomic.Value(isize),

    pub fn init(max_bytes: usize) MemoryBudget {
        return .{ .remaining = .init(@intCast(max_bytes)) };
    }

    pub fn tryAcquire(self: *MemoryBudget, bytes: usize) bool {
        const signed_bytes: isize = @intCast(bytes);
        while (true) {
            const current = self.remaining.load(.monotonic);
            if (current < signed_bytes) return false;
            if (self.remaining.cmpxchgWeak(
                @intCast(current),
                @intCast(current - signed_bytes),
                .monotonic,
                .monotonic,
            )) |_| {
                return true;
            } else continue;
        }
    }

    pub fn release(self: *MemoryBudget, bytes: usize) void {
        _ = self.remaining.fetchAdd(@intCast(bytes), .monotonic);
    }
};

const Shared = struct {
    payload_file: std.Io.File,
    io: std.Io,
    plan: *const extract_plan.Plan,
    task_queue: *TaskQueue,
    completed_tasks: std.atomic.Value(usize),
    total_tasks: usize,
    worker_count: usize,
    window_size: usize,
    partitions: []PartitionWriteState,
    budget: *MemoryBudget,
    tracker: *progress.ProgressTracker,
    collector: *progress.ErrorCollector,
    data_offset: u64,
    spill_dir: []const u8,
    old_dir: ?[]const u8,
    bsdiff_enabled: bool,
    allocator: std.mem.Allocator,
};

// ---------------------------------------------------------------------------
// Main entry
// ---------------------------------------------------------------------------

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
    old_dir: ?[]const u8,
    bsdiff_enabled: bool,
) Error!void {

    // --- Phase 1: Disk space check ---
    var required_bytes: u64 = 0;
    for (plan.jobs) |job| {
        required_bytes = std.math.add(u64, required_bytes, job.total_output_bytes) catch return error.IntegerOverflow;
    }

    const available_bytes = getAvailableBytes(output_dir) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "failed to check disk space for output directory '{s}'", .{output_dir}) catch null;
        if (msg) |m| collector.addOwned(m);
        return err;
    };

    if (available_bytes < required_bytes) {
        var req_buf: [64]u8 = undefined;
        var avail_buf: [64]u8 = undefined;
        const req_str = formatSize(&req_buf, required_bytes);
        const avail_str = formatSize(&avail_buf, available_bytes);
        const msg = std.fmt.allocPrint(allocator, "insufficient disk space: output directory '{s}' requires {s} but only {s} is available", .{ output_dir, req_str, avail_str }) catch null;
        if (msg) |m| collector.addOwned(m);
        return error.InsufficientDiskSpace;
    }

    // --- Phase 2: Prepare spill directory and memory budget ---
    const spill_dir = try std.fmt.allocPrint(allocator, "{s}/.zpayload_spill", .{output_dir});
    defer allocator.free(spill_dir);
    std.Io.Dir.cwd().createDirPath(io, spill_dir) catch {};

    var budget = MemoryBudget.init(256 * 1024 * 1024); // 256 MB

    // --- Phase 3: Pre-allocate output files and build per-partition write states ---
    var partitions = try allocator.alloc(PartitionWriteState, plan.jobs.len);
    defer {
        for (partitions) |*part| {
            part.output_file.close(io);
            allocator.free(part.output_path);
            var pending_it = part.pending.valueIterator();
            while (pending_it.next()) |chunk| {
                cleanupPendingData(io, allocator, &budget, chunk);
            }
            part.pending.deinit(allocator);
            // job.name, operations and extents are arena-allocated; freed with plan.deinit()
        }
        allocator.free(partitions);
    }

    const window_size = blk: {
        const doubled = std.math.mul(usize, concurrency, 2) catch std.math.maxInt(usize);
        break :blk @max(@as(usize, 1), doubled);
    };

    var queue_capacity: usize = 0;
    for (plan.jobs) |job| {
        queue_capacity = std.math.add(
            usize,
            queue_capacity,
            @min(job.total_operations, window_size),
        ) catch return error.IntegerOverflow;
    }

    const queue_storage = try allocator.alloc(Task, queue_capacity);
    defer allocator.free(queue_storage);
    var task_queue = TaskQueue{ .tasks = queue_storage };

    var total_tasks: usize = 0;
    for (plan.jobs, 0..) |job, pidx| {
        total_tasks = std.math.add(usize, total_tasks, job.total_operations) catch return error.IntegerOverflow;

        const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}.img", .{ output_dir, job.name });
        {
            var out = std.Io.Dir.cwd().createFile(io, output_path, .{ .truncate = true }) catch return error.IoFailure;
            defer out.close(io);
            out.setLength(io, job.total_output_bytes) catch return error.IoFailure;
        }
        const out_file = std.Io.Dir.cwd().openFile(io, output_path, .{ .mode = .read_write }) catch return error.IoFailure;

        const initial_window = @min(job.total_operations, window_size);
        partitions[pidx] = .{
            .job = job,
            .output_path = output_path,
            .output_file = out_file,
            .next_expected_op = .init(0),
            .pending = .empty,
            .pending_mutex = .init,
            .completed_ops = .init(0),
            .has_errors = .init(false),
            .next_enqueued_op = initial_window,
        };

        for (0..initial_window) |oidx| {
            task_queue.push(io, .{ .partition_index = pidx, .operation_index = oidx });
        }
    }

    const worker_count = @min(concurrency, total_tasks);
    const threads = try allocator.alloc(std.Thread, worker_count);
    defer allocator.free(threads);

    var shared = Shared{
        .payload_file = payload_file,
        .io = io,
        .plan = plan,
        .task_queue = &task_queue,
        .completed_tasks = .init(0),
        .total_tasks = total_tasks,
        .worker_count = worker_count,
        .window_size = window_size,
        .partitions = partitions,
        .budget = &budget,
        .tracker = tracker,
        .collector = collector,
        .data_offset = data_offset,
        .spill_dir = spill_dir,
        .old_dir = old_dir,
        .bsdiff_enabled = bsdiff_enabled,
        .allocator = allocator,
    };

    for (threads) |*thread| {
        thread.* = std.Thread.spawn(.{}, workerMain, .{&shared}) catch return error.IoFailure;
    }

    // --- Phase 5: Wait for all workers ---
    for (threads) |thread| thread.join();

    // --- Phase 6: Drain any leftover pending ops on main thread ---
    for (partitions, 0..) |*part, pidx| {
        if (part.has_errors.load(.acquire)) {
            tracker.markFailed(pidx);
            continue;
        }

        var writer_buf: [64 * 1024]u8 = undefined;
        while (true) {
            part.pending_mutex.lockUncancelable(io);
            const next = part.next_expected_op.load(.monotonic);
            const entry = part.pending.fetchRemove(next);
            part.pending_mutex.unlock(io);

            const chunk = if (entry) |kv| kv.value else break;
            const op = part.job.operations[chunk.op_index];
            const data_to_write = switch (chunk.data) {
                .memory => |mem| mem,
                .tmp_file => |path| readSpillFile(&shared, path) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "failed to read spill file for pending op {d} of {s}: {s}", .{ chunk.op_index, part.job.name, @errorName(err) }) catch null;
                    if (msg) |m| collector.addOwned(m);
                    cleanupPendingData(io, shared.allocator, &budget, &chunk);
                    part.has_errors.store(true, .release);
                    break;
                },
            };
            const success = writeOpData(io, part.output_file, &writer_buf, op, data_to_write) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "failed to drain pending op {d} for {s}: {s}", .{ chunk.op_index, part.job.name, @errorName(err) }) catch null;
                if (msg) |m| collector.addOwned(m);
                cleanupPendingData(io, shared.allocator, &budget, &chunk);
                part.has_errors.store(true, .release);
                break;
            };
            if (!success) {
                cleanupPendingData(io, shared.allocator, &budget, &chunk);
                part.has_errors.store(true, .release);
                break;
            }
            cleanupPendingData(io, shared.allocator, &budget, &chunk);
            part.pending_mutex.lockUncancelable(io);
            part.next_expected_op.store(next + 1, .monotonic);
            part.pending_mutex.unlock(io);
        }

        if (!part.has_errors.load(.acquire)) {
            tracker.markDone(pidx);
        } else {
            tracker.markFailed(pidx);
        }
    }

    // --- Phase 7: Cleanup spill directory ---
    std.Io.Dir.cwd().deleteTree(io, spill_dir) catch {};
}

// ---------------------------------------------------------------------------
// Worker thread
// ---------------------------------------------------------------------------

fn workerMain(shared: *Shared) void {
    var compress_in_buf: [compress.chunk_size]u8 = undefined;
    var compress_out_buf: [compress.chunk_size]u8 = undefined;
    var zero_buf: [1024 * 1024]u8 = undefined;
    var writer_buf: [64 * 1024]u8 = undefined;
    var buffer = std.Io.Writer.Allocating.init(shared.allocator);
    defer buffer.deinit();
    @memset(&zero_buf, 0);

    while (true) {
        const task = shared.task_queue.pop(shared.io) orelse break;
        const part = &shared.partitions[task.partition_index];
        const op = part.job.operations[task.operation_index];

        if (task.operation_index == 0) {
            shared.tracker.markRunning(task.partition_index);
        }

        if (part.has_errors.load(.acquire)) {
            scheduleNextTask(shared, task.partition_index);
            finishTask(shared, task.partition_index, false);
            continue;
        }

        buffer.clearRetainingCapacity();
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});

        const write_result = materializeOperationBuffer(
            shared,
            part.job.name,
            op,
            &hasher,
            &buffer,
            &compress_in_buf,
            &compress_out_buf,
            &zero_buf,
        );

        if (write_result) |_| {} else |err| {
            recordError(shared, part, task.operation_index, err);
            scheduleNextTask(shared, task.partition_index);
            finishTask(shared, task.partition_index, false);
            continue;
        }

        const data = buffer.written();

        // Try to write directly or buffer.
        part.pending_mutex.lockUncancelable(shared.io);
        if (task.operation_index == part.next_expected_op.load(.monotonic)) {
            part.pending_mutex.unlock(shared.io);

            // Direct write
            const success = writeOpData(shared.io, part.output_file, &writer_buf, op, data) catch |err| {
                recordError(shared, part, task.operation_index, err);
                scheduleNextTask(shared, task.partition_index);
                finishTask(shared, task.partition_index, false);
                continue;
            };
            if (!success) {
                recordError(shared, part, task.operation_index, error.UnexpectedBytesWritten);
                scheduleNextTask(shared, task.partition_index);
                finishTask(shared, task.partition_index, false);
                continue;
            }

            part.pending_mutex.lockUncancelable(shared.io);
            part.next_expected_op.store(task.operation_index + 1, .monotonic);
            flushPending(shared, part);
            part.pending_mutex.unlock(shared.io);
        } else {
            // Buffer in memory or spill to temp file
            const acquired = if (data.len > 0) shared.budget.tryAcquire(data.len) else true;
            if (acquired) {
                const copy = shared.allocator.dupe(u8, data) catch {
                    part.pending_mutex.unlock(shared.io);
                    recordError(shared, part, task.operation_index, error.OutOfMemory);
                    scheduleNextTask(shared, task.partition_index);
                    finishTask(shared, task.partition_index, false);
                    continue;
                };
                part.pending.put(shared.allocator, task.operation_index, .{
                    .op_index = task.operation_index,
                    .data = .{ .memory = copy },
                }) catch {
                    part.pending_mutex.unlock(shared.io);
                    shared.allocator.free(copy);
                    shared.budget.release(data.len);
                    recordError(shared, part, task.operation_index, error.OutOfMemory);
                    scheduleNextTask(shared, task.partition_index);
                    finishTask(shared, task.partition_index, false);
                    continue;
                };
            } else {
                // Spill to temp file
                const tmp_path = std.fmt.allocPrint(shared.allocator, "{s}/p{d}_op{d}.tmp", .{ shared.spill_dir, task.partition_index, task.operation_index }) catch {
                    part.pending_mutex.unlock(shared.io);
                    recordError(shared, part, task.operation_index, error.OutOfMemory);
                    scheduleNextTask(shared, task.partition_index);
                    finishTask(shared, task.partition_index, false);
                    continue;
                };
                var tmp_file = std.Io.Dir.cwd().createFile(shared.io, tmp_path, .{ .truncate = true }) catch |err| {
                    part.pending_mutex.unlock(shared.io);
                    shared.allocator.free(tmp_path);
                    recordError(shared, part, task.operation_index, err);
                    scheduleNextTask(shared, task.partition_index);
                    finishTask(shared, task.partition_index, false);
                    continue;
                };
                var tmp_buf: [64 * 1024]u8 = undefined;
                var tmp_writer = tmp_file.writer(shared.io, &tmp_buf);
                tmp_writer.interface.writeAll(data) catch |err| {
                    tmp_file.close(shared.io);
                    std.Io.Dir.cwd().deleteFile(shared.io, tmp_path) catch {};
                    shared.allocator.free(tmp_path);
                    part.pending_mutex.unlock(shared.io);
                    recordError(shared, part, task.operation_index, err);
                    scheduleNextTask(shared, task.partition_index);
                    finishTask(shared, task.partition_index, false);
                    continue;
                };
                tmp_writer.flush() catch |err| {
                    tmp_file.close(shared.io);
                    std.Io.Dir.cwd().deleteFile(shared.io, tmp_path) catch {};
                    shared.allocator.free(tmp_path);
                    part.pending_mutex.unlock(shared.io);
                    recordError(shared, part, task.operation_index, err);
                    scheduleNextTask(shared, task.partition_index);
                    finishTask(shared, task.partition_index, false);
                    continue;
                };
                tmp_file.close(shared.io);
                part.pending.put(shared.allocator, task.operation_index, .{
                    .op_index = task.operation_index,
                    .data = .{ .tmp_file = tmp_path },
                }) catch {
                    part.pending_mutex.unlock(shared.io);
                    std.Io.Dir.cwd().deleteFile(shared.io, tmp_path) catch {};
                    shared.allocator.free(tmp_path);
                    recordError(shared, part, task.operation_index, error.OutOfMemory);
                    scheduleNextTask(shared, task.partition_index);
                    finishTask(shared, task.partition_index, false);
                    continue;
                };
            }
            part.pending_mutex.unlock(shared.io);
        }

        scheduleNextTask(shared, task.partition_index);
        finishTask(shared, task.partition_index, true);
    }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn writeOpData(
    io: std.Io,
    output_file: std.Io.File,
    writer_buf: []u8,
    op: extract_plan.Operation,
    data: []const u8,
) Error!bool {
    var file_writer = output_file.writer(io, writer_buf);
    var cursor = extent_writer.ExtentCursor.init(op.extents, op.expected_uncompressed, &file_writer);
    cursor.writeAll(data) catch return error.IoFailure;
    cursor.finish() catch return error.UnexpectedBytesWritten;
    file_writer.flush() catch return error.IoFailure;
    return true;
}

fn flushPending(shared: *Shared, part: *PartitionWriteState) void {
    var writer_buf: [64 * 1024]u8 = undefined;
    while (true) {
        const next = part.next_expected_op.load(.monotonic);
        const chunk = if (part.pending.fetchRemove(next)) |kv| kv.value else break;
        const op = part.job.operations[chunk.op_index];

        part.pending_mutex.unlock(shared.io);
        const is_spill = chunk.data == .tmp_file;
        const data: []const u8 = switch (chunk.data) {
            .memory => |mem| mem,
            .tmp_file => |path| readSpillFile(shared, path) catch |err| {
                shared.allocator.free(path);
                recordError(shared, part, chunk.op_index, err);
                part.pending_mutex.lockUncancelable(shared.io);
                return;
            },
        };
        defer if (is_spill) shared.allocator.free(data);
        const success = writeOpData(shared.io, part.output_file, &writer_buf, op, data) catch |err| {
            cleanupPendingData(shared.io, shared.allocator, shared.budget, &chunk);
            recordError(shared, part, chunk.op_index, err);
            part.pending_mutex.lockUncancelable(shared.io);
            return;
        };
        if (!success) {
            cleanupPendingData(shared.io, shared.allocator, shared.budget, &chunk);
            recordError(shared, part, chunk.op_index, error.UnexpectedBytesWritten);
            part.pending_mutex.lockUncancelable(shared.io);
            return;
        }
        cleanupPendingData(shared.io, shared.allocator, shared.budget, &chunk);
        part.pending_mutex.lockUncancelable(shared.io);
        part.next_expected_op.store(next + 1, .monotonic);
    }
}

fn materializeOperationBuffer(
    shared: *Shared,
    partition_name: []const u8,
    op: extract_plan.Operation,
    hasher: *std.crypto.hash.sha2.Sha256,
    buffer: *std.Io.Writer.Allocating,
    compress_in_buf: []u8,
    compress_out_buf: []u8,
    zero_buf: []u8,
) Error!usize {
    const written = switch (op.op_type) {
        .replace => try compress.copyRawToWriter(shared.payload_file, shared.io, op.blob_offset, op.blob_length, hasher, &buffer.writer, compress_in_buf),
        .replace_xz => try compress.decompressXzToWriter(shared.payload_file, shared.io, op.blob_offset, op.blob_length, hasher, &buffer.writer, shared.allocator),
        .replace_bz => try compress.decompressBz2ToWriter(shared.payload_file, shared.io, op.blob_offset, op.blob_length, hasher, &buffer.writer, compress_in_buf, compress_out_buf),
        .zstd => try compress.decompressZstdToWriter(shared.payload_file, shared.io, op.blob_offset, op.blob_length, hasher, &buffer.writer, shared.allocator),
        .zero => try materializeZeroBuffer(shared, op, hasher, buffer, zero_buf),
        .source_copy => try materializeSourceCopy(shared, partition_name, op, hasher, buffer),
        .source_bsdiff => try materializeSourceBsdiff(shared, partition_name, op, buffer),
        else => return error.UnhandledOperationType,
    };

    if (op.op_type != .source_bsdiff) {
        try verifySha256Hash(op.sha256, hasher);
    }
    if (written != op.expected_uncompressed) return error.UnexpectedBytesWritten;
    return written;
}

fn materializeSourceBsdiff(
    shared: *Shared,
    partition_name: []const u8,
    op: extract_plan.Operation,
    buffer: *std.Io.Writer.Allocating,
) Error!usize {
    if (!shared.bsdiff_enabled) return error.UnhandledOperationType;
    const old_dir = shared.old_dir orelse return error.MissingOldImage;

    const path = std.fmt.allocPrint(shared.allocator, "{s}/{s}.img", .{ old_dir, partition_name }) catch return error.OutOfMemory;
    defer shared.allocator.free(path);

    var old_file = std.Io.Dir.cwd().openFile(shared.io, path, .{ .mode = .read_only }) catch return error.IoFailure;
    defer old_file.close(shared.io);

    var old_data = std.array_list.Managed(u8).init(shared.allocator);
    defer old_data.deinit();

    var read_buf: [64 * 1024]u8 = undefined;
    var src_hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (op.src_extents) |extent| {
        var remaining = extent.length_bytes;
        var position = extent.offset_bytes;
        while (remaining > 0) {
            const chunk_len: usize = @intCast(@min(remaining, read_buf.len));
            const n = old_file.readPositionalAll(shared.io, read_buf[0..chunk_len], position) catch return error.IoFailure;
            if (n != chunk_len) return error.IoFailure;
            old_data.appendSlice(read_buf[0..chunk_len]) catch return error.OutOfMemory;
            src_hasher.update(read_buf[0..chunk_len]);
            remaining -= chunk_len;
            position += chunk_len;
        }
    }

    if (op.src_sha256) |expected| {
        var hash: [32]u8 = undefined;
        src_hasher.final(&hash);
        if (!std.mem.eql(u8, expected, &hash)) return error.ChecksumMismatch;
    }

    // Read patch blob from payload
    var patch_data = shared.allocator.alloc(u8, op.blob_length) catch return error.OutOfMemory;
    defer shared.allocator.free(patch_data);
    {
        var pos: u64 = 0;
        while (pos < op.blob_length) {
            const n = shared.payload_file.readPositionalAll(shared.io, patch_data[pos..], op.blob_offset + pos) catch return error.IoFailure;
            if (n == 0) return error.IoFailure;
            pos += n;
        }
    }
    try verifySha256Bytes(op.sha256, patch_data);

    const result = bsdiff.applyPatch(shared.allocator, old_data.items, patch_data, @intCast(op.expected_uncompressed)) catch |err| return err;
    defer shared.allocator.free(result);

    buffer.writer.writeAll(result) catch return error.IoFailure;
    return result.len;
}

fn materializeSourceCopy(
    shared: *Shared,
    partition_name: []const u8,
    op: extract_plan.Operation,
    hasher: *std.crypto.hash.sha2.Sha256,
    buffer: *std.Io.Writer.Allocating,
) Error!usize {
    const old_dir = shared.old_dir orelse return error.MissingOldImage;

    const path = std.fmt.allocPrint(shared.allocator, "{s}/{s}.img", .{ old_dir, partition_name }) catch return error.OutOfMemory;
    defer shared.allocator.free(path);

    var file = std.Io.Dir.cwd().openFile(shared.io, path, .{ .mode = .read_only }) catch return error.IoFailure;
    defer file.close(shared.io);

    var total_read: usize = 0;
    var read_buf: [64 * 1024]u8 = undefined;
    var src_hasher = std.crypto.hash.sha2.Sha256.init(.{});

    for (op.src_extents) |extent| {
        var remaining = extent.length_bytes;
        var position = extent.offset_bytes;
        while (remaining > 0) {
            const chunk_len: usize = @intCast(@min(remaining, read_buf.len));
            const n = file.readPositionalAll(shared.io, read_buf[0..chunk_len], position) catch return error.IoFailure;
            if (n != chunk_len) return error.IoFailure;
            hasher.update(read_buf[0..chunk_len]);
            src_hasher.update(read_buf[0..chunk_len]);
            buffer.writer.writeAll(read_buf[0..chunk_len]) catch return error.IoFailure;
            total_read += chunk_len;
            remaining -= chunk_len;
            position += chunk_len;
        }
    }

    if (op.src_sha256) |expected| {
        var hash: [32]u8 = undefined;
        src_hasher.final(&hash);
        if (!std.mem.eql(u8, expected, &hash)) return error.ChecksumMismatch;
    }

    return total_read;
}

fn materializeZeroBuffer(
    shared: *Shared,
    op: extract_plan.Operation,
    hasher: *std.crypto.hash.sha2.Sha256,
    buffer: *std.Io.Writer.Allocating,
    zero_buf: []u8,
) Error!usize {
    var remaining = op.blob_length;
    var position = op.blob_offset;
    while (remaining > 0) {
        const chunk_len: usize = @intCast(@min(remaining, zero_buf.len));
        const read_count = shared.payload_file.readPositionalAll(shared.io, zero_buf[0..chunk_len], position) catch return error.IoFailure;
        std.debug.assert(read_count == chunk_len);
        hasher.update(zero_buf[0..chunk_len]);
        remaining -= chunk_len;
        position += chunk_len;
    }

    const len: usize = @intCast(op.expected_uncompressed);
    const zeroes = buffer.writer.writableSlice(len) catch return error.OutOfMemory;
    @memset(zeroes, 0);
    return op.expected_uncompressed;
}

fn scheduleNextTask(shared: *Shared, partition_index: usize) void {
    const part = &shared.partitions[partition_index];
    shared.task_queue.mutex.lockUncancelable(shared.io);
    defer shared.task_queue.mutex.unlock(shared.io);

    if (shared.task_queue.closed) return;
    if (part.next_enqueued_op >= part.job.total_operations) return;

    std.debug.assert(shared.task_queue.len < shared.task_queue.tasks.len);
    shared.task_queue.tasks[shared.task_queue.tail] = .{
        .partition_index = partition_index,
        .operation_index = part.next_enqueued_op,
    };
    shared.task_queue.tail = (shared.task_queue.tail + 1) % shared.task_queue.tasks.len;
    shared.task_queue.len += 1;
    part.next_enqueued_op += 1;
    shared.task_queue.semaphore.post(shared.io);
}

fn finishTask(shared: *Shared, partition_index: usize, update_progress: bool) void {
    const part = &shared.partitions[partition_index];
    const completed = part.completed_ops.fetchAdd(1, .release) + 1;
    if (update_progress) {
        shared.tracker.updateOps(partition_index, completed);
        if (completed >= part.job.total_operations) {
            shared.tracker.markDone(partition_index);
        }
    }

    const total_completed = shared.completed_tasks.fetchAdd(1, .release) + 1;
    if (total_completed == shared.total_tasks) {
        shared.task_queue.close(shared.io, shared.worker_count);
    }
}

fn readSpillFile(shared: *Shared, path: []const u8) Error![]u8 {
    var file = std.Io.Dir.cwd().openFile(shared.io, path, .{ .mode = .read_only }) catch return error.IoFailure;
    defer file.close(shared.io);
    const size = file.length(shared.io) catch return error.IoFailure;
    const buf = shared.allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer shared.allocator.free(buf);
    var pos: u64 = 0;
    while (pos < size) {
        const n = file.readPositionalAll(shared.io, buf[pos..], pos) catch return error.IoFailure;
        if (n == 0) return error.IoFailure;
        pos += n;
    }
    return buf;
}

fn cleanupPendingData(io: std.Io, allocator: std.mem.Allocator, budget: *MemoryBudget, chunk: *const PendingChunk) void {
    switch (chunk.data) {
        .memory => |mem| {
            budget.release(mem.len);
            allocator.free(mem);
        },
        .tmp_file => |path| {
            std.Io.Dir.cwd().deleteFile(io, path) catch {};
            allocator.free(path);
        },
    }
}

fn recordError(shared: *Shared, part: *PartitionWriteState, operation_index: usize, err: anyerror) void {
    const msg = if (err == error.MissingOldImage)
        std.fmt.allocPrint(shared.allocator, "failed to process {s} op{d}: {s} (use --old <dir> to provide source partition images for delta payload)", .{
            part.job.name,
            operation_index,
            @errorName(err),
        }) catch null
    else
        std.fmt.allocPrint(shared.allocator, "failed to process {s} op{d}: {s}", .{
            part.job.name,
            operation_index,
            @errorName(err),
        }) catch null;
    if (msg) |m| shared.collector.addOwned(m);
    part.has_errors.store(true, .release);
}

fn verifySha256Hash(expected: ?[]const u8, hasher: *std.crypto.hash.sha2.Sha256) Error!void {
    if (expected) |value| {
        var hash: [32]u8 = undefined;
        hasher.final(&hash);
        if (!std.mem.eql(u8, value, &hash)) return error.ChecksumMismatch;
    }
}

fn verifySha256Bytes(expected: ?[]const u8, data: []const u8) Error!void {
    if (expected) |value| {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(data);
        try verifySha256Hash(value, &hasher);
    }
}

test "verifySha256Bytes matches SOURCE_BSDIFF patch blob semantics" {
    var patch_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("patch-bytes", &patch_hash, .{});

    try verifySha256Bytes(&patch_hash, "patch-bytes");
    try std.testing.expectError(error.ChecksumMismatch, verifySha256Bytes(&patch_hash, "patched-output"));
}
