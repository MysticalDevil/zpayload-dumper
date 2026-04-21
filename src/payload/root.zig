const std = @import("std");
const errors = @import("../errors.zig");
const upb = @import("../ffi/upb.zig");
const header = @import("header.zig");
const progress = @import("progress.zig");
const extract_plan = @import("extract_plan.zig");
const engine = @import("engine.zig");

pub const block_size: u64 = 4096;
pub const Error = errors.AppError;
pub const Reporter = progress.Reporter;
pub const Sink = progress.Sink;

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
    ctx: upb.Context = undefined,
    ctx_initialized: bool = false,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) Error!Payload {
        const file = std.Io.Dir.cwd().openFile(io, filename, .{}) catch return error.IoFailure;
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .header = .{},
            .metadata_size = 0,
            .data_offset = 0,
            .ctx = undefined,
            .ctx_initialized = false,
        };
    }

    pub fn deinit(self: *Payload) void {
        if (self.ctx_initialized) {
            self.ctx.deinit();
            self.ctx_initialized = false;
        }
        if (self.file) |file| file.close(self.io);
    }

    pub fn init(self: *Payload) Error!void {
        const file = self.file orelse return error.IoFailure;
        self.header = try header.readHeader(file, self.io);

        const manifest_buf = try header.readAtAlloc(self.allocator, file, self.io, 24, self.header.manifest_len);
        defer self.allocator.free(manifest_buf);
        const signature_off = 24 + self.header.manifest_len;
        const signature_buf = try header.readAtAlloc(self.allocator, file, self.io, signature_off, self.header.metadata_signature_len);
        defer self.allocator.free(signature_buf);

        self.ctx = try upb.Context.init(manifest_buf, signature_buf);
        self.ctx_initialized = true;
        self.metadata_size = 24 + self.header.manifest_len;
        self.data_offset = self.metadata_size + self.header.metadata_signature_len;
    }

    pub fn initFromMetadata(self: *Payload, manifest: []const u8, signature: []const u8) Error!void {
        self.header = .{
            .version = 2,
            .manifest_len = manifest.len,
            .metadata_signature_len = signature.len,
        };
        self.ctx = try upb.Context.init(manifest, signature);
        self.ctx_initialized = true;
        self.metadata_size = 24 + self.header.manifest_len;
        self.data_offset = self.metadata_size + self.header.metadata_signature_len;
    }

    pub fn printPartitionList(self: *Payload, writer: *std.Io.Writer) Error!void {
        if (!self.ctx_initialized) return error.ManifestNotInitialized;
        const ctx = self.ctx;
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
        if (!self.ctx_initialized) return error.ManifestNotInitialized;
        return self.ctx.partitionCount();
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
        if (!self.ctx_initialized) return error.ManifestNotInitialized;
        const ctx = self.ctx;
        if (concurrency < 1) return error.InvalidConcurrency;

        var plan = try extract_plan.buildPlan(self.allocator, ctx, self.data_offset, selected);
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
                )) |_| null else |err| err;
                done.store(true, .release);
            }
        }.run, .{ &engine_err, &engine_done, self, &plan, output_dir, concurrency, &tracker, &collector }) catch return error.IoFailure;

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

        engine_thread.join();

        sink.render_fn(&tracker, reporter, &prev_lines) catch |err| {
            std.log.warn("failed to render final progress: {}", .{err});
        };

        if (engine_err) |err| {
            if (collector.hasErrors()) {
                sink.print_errors_fn(&collector, reporter) catch {};
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
    ) Error!void {
        if (!self.ctx_initialized) return error.ManifestNotInitialized;
        const ctx = self.ctx;
        if (concurrency < 1) return error.InvalidConcurrency;

        var plan = try extract_plan.buildPlan(self.allocator, ctx, self.data_offset, selected);
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

        var prev_lines: usize = 0;
        var last_render_ns: i96 = 0;

        const worker_count = @min(concurrency, plan.jobs.len);
        const threads = try self.allocator.alloc(std.Thread, worker_count);
        defer self.allocator.free(threads);

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

        for (threads) |thread| thread.join();

        sink.render_fn(&tracker, reporter, &prev_lines) catch |err| {
            std.log.warn("failed to render final dry-run progress: {}", .{err});
        };

        if (worker_failed.load(.acquire)) return error.IoFailure;
    }
};

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
