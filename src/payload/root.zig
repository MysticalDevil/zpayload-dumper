const std = @import("std");
const errors = @import("../errors.zig");
const upb = @import("../ffi/upb.zig");
const compress = @import("../ffi/compress.zig");
const header = @import("header.zig");
const progress = @import("progress.zig");
const extent_writer = @import("extent_writer.zig");

pub const block_size: u64 = 4096;
pub const Error = errors.AppError;
pub const Reporter = progress.Reporter;
pub const Sink = progress.Sink;

pub const Payload = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    header: header.Header = .{},
    metadata_size: u64 = 0,
    data_offset: u64 = 0,
    ctx: ?upb.Context = null,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) Error!Payload {
        const file = std.Io.Dir.cwd().openFile(io, filename, .{}) catch return error.IoFailure;
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
        };
    }

    pub fn deinit(self: *Payload) void {
        if (self.ctx) |*ctx| ctx.deinit();
        self.file.close(self.io);
    }

    pub fn init(self: *Payload) Error!void {
        self.header = try header.readHeader(self.file, self.io);

        const manifest_buf = try header.readAtAlloc(self.allocator, self.file, self.io, 24, self.header.manifest_len);
        defer self.allocator.free(manifest_buf);
        const signature_off = 24 + self.header.manifest_len;
        const signature_buf = try header.readAtAlloc(self.allocator, self.file, self.io, signature_off, self.header.metadata_signature_len);
        defer self.allocator.free(signature_buf);

        self.ctx = try upb.Context.init(manifest_buf, signature_buf);
        self.metadata_size = 24 + self.header.manifest_len;
        self.data_offset = self.metadata_size + self.header.metadata_signature_len;
    }

    pub fn printPartitionList(self: *Payload, writer: *std.Io.Writer) Error!void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        writer.writeAll("Found partitions:\n") catch return error.IoFailure;
        const count = ctx.partitionCount();
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const name = ctx.partitionName(index) orelse continue;
            writer.print("  {s} (", .{name}) catch return error.IoFailure;
            printSizeKbMb(writer, ctx.partitionSize(index)) catch return error.IoFailure;
            writer.writeAll(")\n") catch return error.IoFailure;
        }
    }

    pub fn partitionCount(self: *Payload) Error!usize {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        return ctx.partitionCount();
    }

    pub fn extractAll(
        self: *Payload,
        output_dir: []const u8,
        concurrency: usize,
        reporter: *const Reporter,
        sink: progress.Sink,
    ) Error!void {
        return self.extractSelected(output_dir, &.{}, concurrency, reporter, sink);
    }

    pub fn extractSelected(
        self: *Payload,
        output_dir: []const u8,
        selected: []const []const u8,
        concurrency: usize,
        reporter: *const Reporter,
        sink: progress.Sink,
    ) Error!void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        if (concurrency < 1) return error.InvalidConcurrency;

        var jobs = std.array_list.Managed(progress.Job).init(self.allocator);
        defer jobs.deinit();

        const part_count = ctx.partitionCount();
        var partition_index: usize = 0;
        while (partition_index < part_count) : (partition_index += 1) {
            const name = ctx.partitionName(partition_index) orelse continue;
            if (selected.len != 0 and !containsPartition(selected, name)) continue;
            try jobs.append(.{
                .pidx = partition_index,
                .name = name,
                .total_ops = ctx.operationCount(partition_index),
            });
        }

        if (jobs.items.len == 0) return;

        var tracker = try progress.ProgressTracker.init(self.allocator, self.io, jobs.items);
        defer tracker.deinit(self.allocator);

        var collector = progress.ErrorCollector.init(self.allocator, self.io);
        defer collector.deinit();

        var next_job = std.atomic.Value(usize).init(0);
        var completed_jobs = std.atomic.Value(usize).init(0);

        const worker_count = @min(concurrency, jobs.items.len);
        const threads = try self.allocator.alloc(std.Thread, worker_count);
        defer self.allocator.free(threads);

        var shared = WorkerShared{
            .payload = self,
            .ctx = ctx,
            .jobs = jobs.items,
            .output_dir = output_dir,
            .next_job = &next_job,
            .completed_jobs = &completed_jobs,
            .tracker = &tracker,
            .collector = &collector,
        };

        for (threads) |*thread| {
            thread.* = std.Thread.spawn(.{}, workerMain, .{&shared}) catch return error.IoFailure;
        }

        var prev_lines: usize = 0;
        var last_render_ns: i96 = 0;
        while (completed_jobs.load(.acquire) < jobs.items.len) {
            const now_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
            const force_refresh = now_ns - last_render_ns >= 250 * std.time.ns_per_ms;
            if (tracker.consumeDirty() or force_refresh) {
                sink.render(&tracker, reporter, &prev_lines) catch |err| {
                    std.log.warn("failed to render progress: {}", .{err});
                };
                last_render_ns = now_ns;
            }
            const sleep_result = self.io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake);
            sleep_result catch return error.IoFailure;
        }

        for (threads) |thread| thread.join();

        sink.render(&tracker, reporter, &prev_lines) catch |err| {
            std.log.warn("failed to render final progress: {}", .{err});
        };

        if (collector.hasErrors()) {
            sink.printErrors(&collector, reporter) catch return error.IoFailure;
            return error.ExtractFailed;
        }
    }

    fn extractPartition(
        self: *Payload,
        ctx: upb.Context,
        partition_index: usize,
        out: std.Io.File,
        tracker: *progress.ProgressTracker,
        tracker_index: usize,
    ) Error!void {
        var writer_buf: [64 * 1024]u8 = undefined;
        var file_writer = out.writer(self.io, &writer_buf);
        errdefer file_writer.flush() catch {};

        const op_count = ctx.operationCount(partition_index);
        var operation_index: usize = 0;
        while (operation_index < op_count) : (operation_index += 1) {
            const extent_count = ctx.dstExtentCount(partition_index, operation_index);
            if (extent_count == 0) return error.InvalidDstExtents;

            const blob_len_u64 = ctx.operationDataLength(partition_index, operation_index);
            const blob_off_u64 = ctx.operationDataOffset(partition_index, operation_index);
            const blob_abs = std.math.add(u64, self.data_offset, blob_off_u64) catch return error.IntegerOverflow;
            const expected_uncompressed = try extent_writer.sumExtentBytes(ctx, partition_index, operation_index, extent_count);
            const op_type = ctx.operationType(partition_index, operation_index) orelse return error.UnhandledOperationType;
            var cursor = extent_writer.ExtentCursor.init(ctx, partition_index, operation_index, extent_count, expected_uncompressed, &file_writer);
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});

            switch (op_type) {
                .replace => {
                    const bytes_written = try compress.copyRawToWriter(self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
                    std.debug.assert(bytes_written <= blob_len_u64);
                },
                .replace_xz => {
                    const bytes_written = try compress.decompressXzToWriter(self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
                    std.debug.assert(bytes_written <= expected_uncompressed);
                },
                .replace_bz => {
                    const bytes_written = try compress.decompressBz2ToWriter(self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
                    std.debug.assert(bytes_written <= expected_uncompressed);
                },
                .zstd => {
                    const bytes_written = try compress.decompressZstdToWriter(self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
                    std.debug.assert(bytes_written <= expected_uncompressed);
                },
                .zero => {
                    var hash_buf: [1024 * 1024]u8 = undefined;
                    var remaining = blob_len_u64;
                    var position = blob_abs;
                    while (remaining > 0) {
                        const chunk_len: usize = @intCast(@min(remaining, hash_buf.len));
                        const read_count = self.file.readPositionalAll(self.io, hash_buf[0..chunk_len], position) catch return error.IoFailure;
                        std.debug.assert(read_count == chunk_len);
                        hasher.update(hash_buf[0..chunk_len]);
                        remaining -= chunk_len;
                        position += chunk_len;
                    }
                    try extent_writer.writeZeroToExtents(self.allocator, &cursor);
                },
                else => return error.UnhandledOperationType,
            }
            try cursor.finish();

            if (ctx.operationSha256(partition_index, operation_index)) |expected| {
                var hash: [32]u8 = undefined;
                hasher.final(&hash);
                if (!std.mem.eql(u8, expected, hash[0..])) return error.ChecksumMismatch;
            }
            tracker.updateOps(tracker_index, operation_index + 1);
        }
        file_writer.flush() catch return error.IoFailure;
    }
};

fn printSizeKbMb(writer: *std.Io.Writer, size_bytes: u64) !void {
    const kb: u64 = 1024;
    const mb: u64 = 1024 * 1024;

    if (size_bytes >= mb) {
        const scaled = @divFloor(size_bytes * 100 + mb / 2, mb);
        const whole = @divFloor(scaled, 100);
        const frac = @mod(scaled, 100);
        try writer.print("{d}.{d:0>2} MB", .{ whole, frac });
        return;
    }

    const scaled = @divFloor(size_bytes * 10 + kb / 2, kb);
    const whole = @divFloor(scaled, 10);
    const frac = @mod(scaled, 10);
    if (frac == 0) {
        try writer.print("{d} KB", .{whole});
        return;
    }
    try writer.print("{d}.{d} KB", .{ whole, frac });
}

const WorkerShared = struct {
    payload: *Payload,
    ctx: upb.Context,
    jobs: []const progress.Job,
    output_dir: []const u8,
    next_job: *std.atomic.Value(usize),
    completed_jobs: *std.atomic.Value(usize),
    tracker: *progress.ProgressTracker,
    collector: *progress.ErrorCollector,
};

fn workerMain(shared: *WorkerShared) void {
    while (true) {
        const index = shared.next_job.fetchAdd(1, .monotonic);
        if (index >= shared.jobs.len) break;

        const job = shared.jobs[index];
        shared.tracker.markRunning(index);

        const out_path = std.fmt.allocPrint(shared.payload.allocator, "{s}/{s}.img", .{ shared.output_dir, job.name }) catch {
            const message = std.fmt.allocPrint(shared.payload.allocator, "failed to allocate output path for partition {s}", .{job.name}) catch null;
            if (message) |owned| {
                shared.collector.addOwned(owned);
            }
            shared.tracker.markFailed(index);
            incrementCompleted(shared.completed_jobs, shared.jobs.len);
            continue;
        };
        defer shared.payload.allocator.free(out_path);

        var out = std.Io.Dir.cwd().createFile(shared.payload.io, out_path, .{ .truncate = true }) catch |err| {
            const message = std.fmt.allocPrint(shared.payload.allocator, "failed to open output for partition {s}: {s}", .{ job.name, @errorName(err) }) catch null;
            if (message) |owned| {
                shared.collector.addOwned(owned);
            }
            shared.tracker.markFailed(index);
            incrementCompleted(shared.completed_jobs, shared.jobs.len);
            continue;
        };
        defer out.close(shared.payload.io);

        shared.payload.extractPartition(shared.ctx, job.pidx, out, shared.tracker, index) catch |err| {
            const message = std.fmt.allocPrint(shared.payload.allocator, "failed to extract partition {s}: {s}", .{ job.name, @errorName(err) }) catch null;
            if (message) |owned| {
                shared.collector.addOwned(owned);
            }
            shared.tracker.markFailed(index);
            incrementCompleted(shared.completed_jobs, shared.jobs.len);
            continue;
        };

        shared.tracker.markDone(index);
        incrementCompleted(shared.completed_jobs, shared.jobs.len);
    }
}

fn incrementCompleted(completed_jobs: *std.atomic.Value(usize), max_jobs: usize) void {
    const previous_completed = completed_jobs.fetchAdd(1, .release);
    std.debug.assert(previous_completed < max_jobs);
}

fn containsPartition(parts: []const []const u8, name: []const u8) bool {
    for (parts) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}
