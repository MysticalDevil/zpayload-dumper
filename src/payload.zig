const std = @import("std");
const errors = @import("errors.zig");
const upb = @import("ffi/upb.zig");
const compress = @import("ffi/compress.zig");
const ui_mod = @import("cli_ui.zig");
const header = @import("payload/header.zig");
const progress = @import("payload/progress.zig");
const extent_writer = @import("payload/extent_writer.zig");

pub const block_size: u64 = 4096;
pub const Error = errors.PayloadError || errors.DecodeError || errors.CompressError || errors.SystemError;
pub const Ui = ui_mod.Ui;
pub const ColorMode = ui_mod.ColorMode;

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

    pub fn printPartitionList(self: *Payload, w: *std.Io.Writer) Error!void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        w.writeAll("Found partitions:\n") catch return error.IoFailure;
        const n = ctx.partitionCount();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const name = ctx.partitionName(i) orelse continue;
            w.print("  {s} ({d} bytes)\n", .{ name, ctx.partitionSize(i) }) catch return error.IoFailure;
        }
    }

    pub fn partitionCount(self: *Payload) Error!usize {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        return ctx.partitionCount();
    }

    pub fn extractAll(self: *Payload, output_dir: []const u8, concurrency: usize, ui: *const ui_mod.Ui) Error!void {
        return self.extractSelected(output_dir, &.{}, concurrency, ui);
    }

    pub fn extractSelected(
        self: *Payload,
        output_dir: []const u8,
        selected: []const []const u8,
        concurrency: usize,
        ui: *const ui_mod.Ui,
    ) Error!void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        if (concurrency < 1) return error.InvalidConcurrency;

        var jobs = std.array_list.Managed(progress.Job).init(self.allocator);
        defer jobs.deinit();

        const part_count = ctx.partitionCount();
        var pidx: usize = 0;
        while (pidx < part_count) : (pidx += 1) {
            const name = ctx.partitionName(pidx) orelse continue;
            if (selected.len != 0 and !containsPartition(selected, name)) continue;
            try jobs.append(.{
                .pidx = pidx,
                .name = name,
                .total_ops = ctx.operationCount(pidx),
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
                progress.renderProgress(&tracker, ui, &prev_lines) catch |err| {
                    std.log.warn("failed to render progress: {}", .{err});
                };
                last_render_ns = now_ns;
            }
            _ = self.io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch return error.IoFailure;
        }

        for (threads) |thread| thread.join();

        progress.renderProgress(&tracker, ui, &prev_lines) catch |err| {
            std.log.warn("failed to render final progress: {}", .{err});
        };

        if (collector.hasErrors()) {
            collector.print(ui) catch return error.IoFailure;
            return error.ExtractFailed;
        }
    }

    fn extractPartition(self: *Payload, ctx: upb.Context, pidx: usize, out: std.Io.File, tracker: *progress.ProgressTracker, tracker_idx: usize) Error!void {
        var writer_buf: [64 * 1024]u8 = undefined;
        var fw = out.writer(self.io, &writer_buf);
        errdefer fw.flush() catch {};

        const op_count = ctx.operationCount(pidx);
        var oidx: usize = 0;
        while (oidx < op_count) : (oidx += 1) {
            const extent_count = ctx.dstExtentCount(pidx, oidx);
            if (extent_count == 0) return error.InvalidDstExtents;

            const blob_len_u64 = ctx.operationDataLength(pidx, oidx);
            const blob_off_u64 = ctx.operationDataOffset(pidx, oidx);
            const blob_abs = self.data_offset + blob_off_u64;
            const expected_uncompressed = extent_writer.sumExtentBytes(ctx, pidx, oidx, extent_count);
            const op_type = ctx.operationType(pidx, oidx) orelse return error.UnhandledOperationType;
            var cursor = extent_writer.ExtentCursor.init(ctx, pidx, oidx, extent_count, expected_uncompressed, &fw);
            var hasher = std.crypto.hash.sha2.Sha256.init(.{});

            switch (op_type) {
                .replace => {
                    _ = try compress.copyRawToWriter(self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
                },
                .replace_xz => {
                    _ = try compress.decompressXzToWriter(self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
                },
                .replace_bz => {
                    _ = try compress.decompressBz2ToWriter(self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
                },
                .zstd => {
                    _ = try compress.decompressZstdToWriter(self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
                },
                .zero => {
                    var hash_buf: [1024 * 1024]u8 = undefined;
                    var remaining = blob_len_u64;
                    var pos = blob_abs;
                    while (remaining > 0) {
                        const n: usize = @intCast(@min(remaining, hash_buf.len));
                        _ = self.file.readPositionalAll(self.io, hash_buf[0..n], pos) catch return error.IoFailure;
                        hasher.update(hash_buf[0..n]);
                        remaining -= n;
                        pos += n;
                    }
                    try extent_writer.writeZeroToExtents(self.allocator, &cursor);
                },
                else => return error.UnhandledOperationType,
            }
            try cursor.finish();

            if (ctx.operationSha256(pidx, oidx)) |expected| {
                var hash: [32]u8 = undefined;
                hasher.final(&hash);
                if (!std.mem.eql(u8, expected, hash[0..])) return error.ChecksumMismatch;
            }
            tracker.updateOps(tracker_idx, oidx + 1);
        }
        fw.flush() catch return error.IoFailure;
    }
};

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
        const idx = shared.next_job.fetchAdd(1, .monotonic);
        if (idx >= shared.jobs.len) break;

        const job = shared.jobs[idx];
        shared.tracker.markRunning(idx);

        const out_path = std.fmt.allocPrint(shared.payload.allocator, "{s}/{s}.img", .{ shared.output_dir, job.name }) catch {
            shared.collector.add("failed to allocate output path for partition {s}", .{job.name});
            shared.tracker.markFailed(idx);
            _ = shared.completed_jobs.fetchAdd(1, .release);
            continue;
        };
        defer shared.payload.allocator.free(out_path);

        var out = std.Io.Dir.cwd().createFile(shared.payload.io, out_path, .{ .truncate = true }) catch |err| {
            shared.collector.add("failed to open output for partition {s}: {s}", .{ job.name, @errorName(err) });
            shared.tracker.markFailed(idx);
            _ = shared.completed_jobs.fetchAdd(1, .release);
            continue;
        };
        defer out.close(shared.payload.io);

        shared.payload.extractPartition(shared.ctx, job.pidx, out, shared.tracker, idx) catch |err| {
            shared.collector.add("failed to extract partition {s}: {s}", .{ job.name, @errorName(err) });
            shared.tracker.markFailed(idx);
            _ = shared.completed_jobs.fetchAdd(1, .release);
            continue;
        };

        shared.tracker.markDone(idx);
        _ = shared.completed_jobs.fetchAdd(1, .release);
    }
}

fn containsPartition(parts: []const []const u8, name: []const u8) bool {
    for (parts) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}
