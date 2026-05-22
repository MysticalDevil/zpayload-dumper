const std = @import("std");
const errors = @import("../errors.zig");
const proto = @import("../proto/chromeos_update_engine.pb.zig");
const header = @import("header.zig");
const progress = @import("progress.zig");
const extract_plan = @import("extract_plan.zig");
const engine = @import("engine.zig");

pub const block_size: u64 = 4096;
pub const Error = errors.AppError;
pub const Reporter = progress.Reporter;
pub const Sink = progress.Sink;
pub const jsonSink = progress.jsonSink;

const DryRunTask = struct {
    tracker: *progress.ProgressTracker,
    jobs: []const progress.Job,
    next_job: *std.atomic.Value(usize),
    completed_jobs: *std.atomic.Value(usize),
    worker_failed: *std.atomic.Value(bool),
    io: std.Io,
};

pub const Payload = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: ?std.Io.File = null,
    header: header.Header = .{},
    metadata_size: u64 = 0,
    data_offset: u64 = 0,
    manifest: proto.DeltaArchiveManifest,
    manifest_initialized: bool = false,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) Error!Payload {
        const file = std.Io.Dir.cwd().openFile(io, filename, .{}) catch |err| switch (err) {
            error.FileNotFound => return error.InputFileNotFound,
            error.AccessDenied => return error.InputFileAccessDenied,
            else => return error.IoFailure,
        };
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .header = .{},
            .metadata_size = 0,
            .data_offset = 0,
            .manifest = undefined,
            .manifest_initialized = false,
        };
    }

    pub fn deinit(self: *Payload) void {
        if (self.manifest_initialized) {
            self.manifest.deinit(self.allocator);
            self.manifest_initialized = false;
        }
        if (self.file) |file| file.close(self.io);
    }

    pub fn init(self: *Payload) Error!void {
        const file = self.file orelse return error.IoFailure;
        self.header = try header.readHeader(file, self.io);

        const manifest_buf = try header.readAtAlloc(self.allocator, file, self.io, 24, self.header.manifest_len);
        defer self.allocator.free(manifest_buf);

        var manifest_reader = std.Io.Reader.fixed(manifest_buf);
        self.manifest = proto.DeltaArchiveManifest.decode(&manifest_reader, self.allocator) catch return error.DecodeFailed;
        self.manifest_initialized = true;
        self.metadata_size = 24 + self.header.manifest_len;
        self.data_offset = self.metadata_size + self.header.metadata_signature_len;
    }

    pub fn initFromMetadata(self: *Payload, manifest_bytes: []const u8) Error!void {
        self.header = .{
            .version = 2,
            .manifest_len = manifest_bytes.len,
            .metadata_signature_len = 0,
        };
        var manifest_reader = std.Io.Reader.fixed(manifest_bytes);
        self.manifest = proto.DeltaArchiveManifest.decode(&manifest_reader, self.allocator) catch return error.DecodeFailed;
        self.manifest_initialized = true;
        self.metadata_size = 24 + self.header.manifest_len;
        self.data_offset = self.metadata_size + self.header.metadata_signature_len;
    }

    pub fn printPartitionList(self: *Payload, writer: *std.Io.Writer) Error!void {
        if (!self.manifest_initialized) return error.ManifestNotInitialized;
        writer.writeAll("Found partitions:\n") catch return error.IoFailure;
        for (self.manifest.partitions.items) |part| {
            const name = part.partition_name;
            writer.print("  {s} (", .{name}) catch return error.IoFailure;
            const size_bytes = if (part.new_partition_info) |info| info.size orelse 0 else 0;
            printSizeKbMb(writer, size_bytes) catch return error.IoFailure;
            writer.writeAll(")\n") catch return error.IoFailure;
        }
    }

    pub fn printPartitionListJson(self: *Payload, writer: *std.Io.Writer) Error!void {
        if (!self.manifest_initialized) return error.ManifestNotInitialized;

        const ManifestInfo = struct {
            type: []const u8,
            total: usize,
            partitions: []const PartitionInfo,
            const PartitionInfo = struct {
                name: []const u8,
                size_bytes: u64,
            };
        };

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        var parts = std.array_list.Managed(ManifestInfo.PartitionInfo).init(aa);
        for (self.manifest.partitions.items) |part| {
            const size_bytes = if (part.new_partition_info) |info| info.size orelse 0 else 0;
            try parts.append(.{ .name = part.partition_name, .size_bytes = size_bytes });
        }

        std.json.Stringify.value(ManifestInfo{
            .type = "partitions",
            .total = self.manifest.partitions.items.len,
            .partitions = parts.items,
        }, .{}, writer) catch return error.IoFailure;
        writer.writeByte('\n') catch return error.IoFailure;
    }

    pub fn partitionCount(self: *Payload) Error!usize {
        if (!self.manifest_initialized) return error.ManifestNotInitialized;
        return self.manifest.partitions.items.len;
    }

    pub fn extractAll(
        self: *Payload,
        output_dir: []const u8,
        concurrency: usize,
        reporter: *const Reporter,
        sink: progress.Sink,
        old_dir: ?[]const u8,
        bsdiff_enabled: bool,
    ) Error!void {
        return self.extractSelected(output_dir, &.{}, concurrency, reporter, sink, old_dir, bsdiff_enabled);
    }

    pub fn extractSelected(
        self: *Payload,
        output_dir: []const u8,
        selected: []const []const u8,
        concurrency: usize,
        reporter: *const Reporter,
        sink: progress.Sink,
        old_dir: ?[]const u8,
        bsdiff_enabled: bool,
    ) Error!void {
        if (!self.manifest_initialized) return error.ManifestNotInitialized;
        if (concurrency < 1) return error.InvalidConcurrency;

        var plan = try extract_plan.buildPlan(self.allocator, &self.manifest, self.data_offset, selected);
        defer plan.deinit();

        if (plan.jobs.len == 0) return;

        var jobs = std.array_list.Managed(progress.Job).init(self.allocator);
        defer jobs.deinit();
        for (plan.jobs) |job| {
            try jobs.append(.{
                .pidx = job.pidx,
                .name = job.name,
                .total_ops = job.total_operations,
            });
        }

        var tracker = try progress.ProgressTracker.init(self.allocator, self.io, jobs.items);
        defer tracker.deinit(self.allocator);

        var collector = progress.ErrorCollector.init(self.allocator, self.io);
        defer collector.deinit();

        // Progress rendering loop runs on main thread while engine works.
        var prev_lines: usize = 0;
        var last_render_ns: i96 = 0;

        // Spawn engine work in a separate thread so main thread can render progress.
        var engine_done = std.atomic.Value(bool).init(false);
        var engine_err: ?Error = null;
        var engine_thread = std.Thread.spawn(.{}, struct {
            fn run(
                e: *?Error,
                done: *std.atomic.Value(bool),
                payload: *Payload,
                plan_ptr: *const extract_plan.Plan,
                out_dir: []const u8,
                c: usize,
                trk: *progress.ProgressTracker,
                coll: *progress.ErrorCollector,
                old: ?[]const u8,
                bsdiff: bool,
            ) void {
                e.* = if (engine.run(
                    payload.allocator,
                    payload.io,
                    payload.file orelse {
                        e.* = error.IoFailure;
                        done.store(true, .release);
                        return;
                    },
                    payload.data_offset,
                    plan_ptr,
                    out_dir,
                    c,
                    trk,
                    coll,
                    old,
                    bsdiff,
                )) |_| null else |err| err;
                done.store(true, .release);
            }
        }.run, .{ &engine_err, &engine_done, self, &plan, output_dir, concurrency, &tracker, &collector, old_dir, bsdiff_enabled }) catch return error.IoFailure;
        defer engine_thread.join();

        while (!engine_done.load(.acquire)) {
            const now_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
            const force_refresh = now_ns - last_render_ns >= 250 * std.time.ns_per_ms;
            if (tracker.consumeDirty() or force_refresh) {
                sink.render_fn(&tracker, reporter, &prev_lines) catch |err| {
                    std.log.warn("failed to render progress: {}", .{err});
                };
                last_render_ns = now_ns;
            }
            const sleep_result = self.io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake);
            sleep_result catch return error.IoFailure;
        }

        sink.render_fn(&tracker, reporter, &prev_lines) catch |err| {
            std.log.warn("failed to render final progress: {}", .{err});
        };

        if (engine_err) |err| {
            if (collector.hasErrors()) {
                sink.print_errors_fn(&collector, reporter) catch |print_err| {
                    std.log.warn("failed to print worker errors: {}", .{print_err});
                };
            }
            return err;
        }

        if (collector.hasErrors()) {
            sink.print_errors_fn(&collector, reporter) catch return error.IoFailure;
            return error.ExtractFailed;
        }
    }

    pub fn extractSelectedDryRun(
        self: *Payload,
        selected: []const []const u8,
        concurrency: usize,
        reporter: *const Reporter,
        sink: progress.Sink,
        old_dir: ?[]const u8,
        bsdiff_enabled: bool,
    ) Error!void {
        if (!self.manifest_initialized) return error.ManifestNotInitialized;
        if (concurrency < 1) return error.InvalidConcurrency;

        var plan = try extract_plan.buildPlan(self.allocator, &self.manifest, self.data_offset, selected);
        defer plan.deinit();

        if (plan.jobs.len == 0) return;
        try validateDryRunPrerequisites(plan.jobs, old_dir, bsdiff_enabled);

        var jobs = std.array_list.Managed(progress.Job).init(self.allocator);
        defer jobs.deinit();
        for (plan.jobs) |job| {
            try jobs.append(.{
                .pidx = job.pidx,
                .name = job.name,
                .total_ops = job.total_operations,
            });
        }

        var tracker = try progress.ProgressTracker.init(self.allocator, self.io, jobs.items);
        defer tracker.deinit(self.allocator);

        var prev_lines: usize = 0;
        var last_render_ns: i96 = 0;

        const worker_count = @min(concurrency, plan.jobs.len);
        const threads = try self.allocator.alloc(std.Thread, worker_count);
        defer self.allocator.free(threads);
        var spawned_threads: usize = 0;
        defer for (threads[0..spawned_threads]) |thread| thread.join();

        var next_job = std.atomic.Value(usize).init(0);
        var completed_jobs = std.atomic.Value(usize).init(0);
        var worker_failed = std.atomic.Value(bool).init(false);

        for (0..worker_count) |idx| {
            threads[idx] = std.Thread.spawn(.{}, dryRunWorker, .{DryRunTask{
                .tracker = &tracker,
                .jobs = jobs.items,
                .next_job = &next_job,
                .completed_jobs = &completed_jobs,
                .worker_failed = &worker_failed,
                .io = self.io,
            }}) catch return error.IoFailure;
            spawned_threads += 1;
        }

        while (completed_jobs.load(.acquire) < jobs.items.len) {
            const now_ns = std.Io.Timestamp.now(self.io, .awake).toNanoseconds();
            const force_refresh = now_ns - last_render_ns >= 250 * std.time.ns_per_ms;
            if (tracker.consumeDirty() or force_refresh) {
                sink.render_fn(&tracker, reporter, &prev_lines) catch |err| {
                    std.log.warn("failed to render dry-run progress: {}", .{err});
                };
                last_render_ns = now_ns;
            }

            self.io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch return error.IoFailure;
        }
        sink.render_fn(&tracker, reporter, &prev_lines) catch |err| {
            std.log.warn("failed to render final dry-run progress: {}", .{err});
        };

        if (worker_failed.load(.acquire)) return error.IoFailure;
    }
};

test "open reports missing input file explicitly" {
    try std.testing.expectError(
        error.InputFileNotFound,
        Payload.open(std.testing.allocator, std.testing.io, "tests/data/generated/does-not-exist/payload.bin"),
    );
}

fn dryRunWorker(task: DryRunTask) void {
    const base_delay_ms: u64 = 20;
    const jitter_ms: u64 = 10;

    while (true) {
        const idx = task.next_job.fetchAdd(1, .acq_rel);
        if (idx >= task.jobs.len) break;

        const job = task.jobs[idx];
        task.tracker.markRunning(idx);
        if (job.total_ops == 0) {
            task.tracker.markDone(idx);
            const completed_after_zero = task.completed_jobs.fetchAdd(1, .acq_rel) + 1;
            std.debug.assert(completed_after_zero <= task.jobs.len);
            continue;
        }

        var job_failed = false;
        var step: usize = 0;
        while (step < job.total_ops) : (step += 1) {
            const sleep_ms = base_delay_ms + @as(u64, @intCast((idx + step) % (jitter_ms + 1)));
            task.io.sleep(.fromNanoseconds(sleep_ms * std.time.ns_per_ms), .awake) catch {
                task.tracker.markFailed(idx);
                task.worker_failed.store(true, .release);
                const completed_after_failure = task.completed_jobs.fetchAdd(1, .acq_rel) + 1;
                std.debug.assert(completed_after_failure <= task.jobs.len);
                job_failed = true;
                break;
            };
            task.tracker.updateOps(idx, step + 1);
        }

        if (job_failed) continue;
        task.tracker.markDone(idx);
        const completed_after_job = task.completed_jobs.fetchAdd(1, .acq_rel) + 1;
        std.debug.assert(completed_after_job <= task.jobs.len);
    }
}

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

fn validateDryRunPrerequisites(
    jobs: []const extract_plan.PartitionJob,
    old_dir: ?[]const u8,
    bsdiff_enabled: bool,
) Error!void {
    for (jobs) |job| {
        for (job.operations) |op| {
            switch (op.op_type) {
                .SOURCE_COPY => if (old_dir == null) return error.MissingOldImage,
                .SOURCE_BSDIFF => {
                    if (!bsdiff_enabled) return error.UnhandledOperationType;
                    if (old_dir == null) return error.MissingOldImage;
                },
                else => {},
            }
        }
    }
}

test "validateDryRunPrerequisites allows non-delta operations" {
    const extents = [_]extract_plan.Extent{.{ .start_block = 0, .num_blocks = 1, .offset_bytes = 0, .length_bytes = block_size }};
    const ops = [_]extract_plan.Operation{.{
        .op_type = .REPLACE,
        .blob_offset = 0,
        .blob_length = 4,
        .expected_uncompressed = block_size,
        .extents = &extents,
        .src_extents = &.{},
        .src_length = 0,
        .sha256 = null,
        .src_sha256 = null,
    }};
    const jobs = [_]extract_plan.PartitionJob{.{
        .pidx = 0,
        .name = "boot",
        .operations = &ops,
        .total_output_bytes = block_size,
        .total_operations = ops.len,
    }};

    try validateDryRunPrerequisites(&jobs, null, false);
}

test "validateDryRunPrerequisites requires old images for source copy" {
    const extents = [_]extract_plan.Extent{.{ .start_block = 0, .num_blocks = 1, .offset_bytes = 0, .length_bytes = block_size }};
    const ops = [_]extract_plan.Operation{.{
        .op_type = .SOURCE_COPY,
        .blob_offset = 0,
        .blob_length = 0,
        .expected_uncompressed = block_size,
        .extents = &extents,
        .src_extents = &extents,
        .src_length = block_size,
        .sha256 = null,
        .src_sha256 = null,
    }};
    const jobs = [_]extract_plan.PartitionJob{.{
        .pidx = 0,
        .name = "boot",
        .operations = &ops,
        .total_output_bytes = block_size,
        .total_operations = ops.len,
    }};

    try std.testing.expectError(error.MissingOldImage, validateDryRunPrerequisites(&jobs, null, false));
    try validateDryRunPrerequisites(&jobs, "/tmp/old", false);
}

test "validateDryRunPrerequisites requires bsdiff support before old images" {
    const extents = [_]extract_plan.Extent{.{ .start_block = 0, .num_blocks = 1, .offset_bytes = 0, .length_bytes = block_size }};
    const ops = [_]extract_plan.Operation{.{
        .op_type = .SOURCE_BSDIFF,
        .blob_offset = 0,
        .blob_length = 4,
        .expected_uncompressed = block_size,
        .extents = &extents,
        .src_extents = &extents,
        .src_length = block_size,
        .sha256 = null,
        .src_sha256 = null,
    }};
    const jobs = [_]extract_plan.PartitionJob{.{
        .pidx = 0,
        .name = "system",
        .operations = &ops,
        .total_output_bytes = block_size,
        .total_operations = ops.len,
    }};

    try std.testing.expectError(error.UnhandledOperationType, validateDryRunPrerequisites(&jobs, null, false));
    try std.testing.expectError(error.MissingOldImage, validateDryRunPrerequisites(&jobs, null, true));
    try validateDryRunPrerequisites(&jobs, "/tmp/old", true);
}
