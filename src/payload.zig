const std = @import("std");
const errors = @import("errors.zig");
const upb = @import("ffi/upb.zig");
const compress = @import("ffi/compress.zig");
const ui_mod = @import("cli_ui.zig");

pub const block_size: u64 = 4096;
pub const Error = errors.AppError;

pub const Payload = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    header: Header = .{},
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
        self.header = try readHeader(self.file, self.io);

        const manifest_buf = try readAtAlloc(self.allocator, self.file, self.io, 24, self.header.manifest_len);
        defer self.allocator.free(manifest_buf);
        const signature_off = 24 + self.header.manifest_len;
        const signature_buf = try readAtAlloc(self.allocator, self.file, self.io, signature_off, self.header.metadata_signature_len);
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

        var jobs = std.array_list.Managed(Job).init(self.allocator);
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

        var tracker = try ProgressTracker.init(self.allocator, self.io, jobs.items);
        defer tracker.deinit(self.allocator);

        var collector = ErrorCollector.init(self.allocator, self.io);
        defer collector.deinit(self.allocator);

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
                renderProgress(&tracker, ui, &prev_lines) catch |err| {
                    std.log.warn("failed to render progress: {}", .{err});
                };
                last_render_ns = now_ns;
            }
            _ = self.io.sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch return error.IoFailure;
        }

        for (threads) |thread| thread.join();

        renderProgress(&tracker, ui, &prev_lines) catch |err| {
            std.log.warn("failed to render final progress: {}", .{err});
        };

        if (collector.hasErrors()) {
            collector.print(ui) catch return error.IoFailure;
            return error.ExtractFailed;
        }
    }

    fn extractPartition(self: *Payload, ctx: upb.Context, pidx: usize, out: std.Io.File, tracker: *ProgressTracker, tracker_idx: usize) Error!void {
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
            const expected_uncompressed = sumExtentBytes(ctx, pidx, oidx, extent_count);
            const op_type = ctx.operationType(pidx, oidx) orelse return error.UnhandledOperationType;
            var cursor = ExtentCursor.init(ctx, pidx, oidx, extent_count, expected_uncompressed, &fw);
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
                    _ = try compress.decompressZstdToWriter(self.allocator, self.file, self.io, blob_abs, blob_len_u64, &hasher, &cursor);
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
                    try writeZeroToExtents(self.allocator, ctx, pidx, oidx, extent_count, &cursor);
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

const Job = struct {
    pidx: usize,
    name: []const u8,
    total_ops: usize,
};

const PartitionState = enum {
    pending,
    running,
    done,
    failed,
};

const PartitionProgress = struct {
    name: []const u8,
    done_ops: usize = 0,
    total_ops: usize = 0,
    state: PartitionState = .pending,
};

const ProgressTracker = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    dirty: std.atomic.Value(bool) = .init(true),
    entries: []PartitionProgress,

    fn init(allocator: std.mem.Allocator, io: std.Io, jobs: []const Job) !ProgressTracker {
        const entries = try allocator.alloc(PartitionProgress, jobs.len);
        for (jobs, 0..) |job, idx| {
            entries[idx] = .{
                .name = job.name,
                .total_ops = job.total_ops,
            };
        }
        return .{
            .io = io,
            .entries = entries,
        };
    }

    fn deinit(self: *ProgressTracker, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    fn markRunning(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .running;
        _ = self.dirty.swap(true, .release);
    }

    fn markDone(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .done;
        self.entries[idx].done_ops = self.entries[idx].total_ops;
        _ = self.dirty.swap(true, .release);
    }

    fn markFailed(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .failed;
        _ = self.dirty.swap(true, .release);
    }

    fn updateOps(self: *ProgressTracker, idx: usize, done_ops: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entries[idx].done_ops != done_ops) {
            self.entries[idx].done_ops = done_ops;
            _ = self.dirty.swap(true, .release);
        }
    }

    fn consumeDirty(self: *ProgressTracker) bool {
        return self.dirty.swap(false, .acq_rel);
    }
};

const ErrorCollector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    messages: std.array_list.Managed([]u8),
    dropped: bool = false,

    fn init(allocator: std.mem.Allocator, io: std.Io) ErrorCollector {
        return .{
            .allocator = allocator,
            .io = io,
            .messages = std.array_list.Managed([]u8).init(allocator),
        };
    }

    fn deinit(self: *ErrorCollector, allocator: std.mem.Allocator) void {
        for (self.messages.items) |msg| allocator.free(msg);
        self.messages.deinit();
    }

    fn hasErrors(self: *ErrorCollector) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.messages.items.len != 0 or self.dropped;
    }

    fn add(self: *ErrorCollector, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(allocator, fmt, args) catch {
            self.mutex.lockUncancelable(self.io);
            self.dropped = true;
            self.mutex.unlock(self.io);
            return;
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.messages.append(msg) catch {
            allocator.free(msg);
            self.dropped = true;
        };
    }

    fn print(self: *ErrorCollector, ui: *const ui_mod.Ui) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.messages.items) |msg| {
            ui.fail("{s}", .{msg}) catch return error.IoFailure;
        }
        if (self.dropped) ui.fail("some worker errors could not be recorded due to allocation failure", .{}) catch return error.IoFailure;
    }
};

const WorkerShared = struct {
    payload: *Payload,
    ctx: upb.Context,
    jobs: []const Job,
    output_dir: []const u8,
    next_job: *std.atomic.Value(usize),
    completed_jobs: *std.atomic.Value(usize),
    tracker: *ProgressTracker,
    collector: *ErrorCollector,
};

fn workerMain(shared: *WorkerShared) void {
    while (true) {
        const idx = shared.next_job.fetchAdd(1, .monotonic);
        if (idx >= shared.jobs.len) break;

        const job = shared.jobs[idx];
        shared.tracker.markRunning(idx);

        const out_path = std.fmt.allocPrint(shared.payload.allocator, "{s}/{s}.img", .{ shared.output_dir, job.name }) catch {
            shared.collector.add(shared.payload.allocator, "failed to allocate output path for partition {s}", .{job.name});
            shared.tracker.markFailed(idx);
            _ = shared.completed_jobs.fetchAdd(1, .release);
            continue;
        };
        defer shared.payload.allocator.free(out_path);

        var out = std.Io.Dir.cwd().createFile(shared.payload.io, out_path, .{ .truncate = true }) catch |err| {
            shared.collector.add(shared.payload.allocator, "failed to open output for partition {s}: {s}", .{ job.name, @errorName(err) });
            shared.tracker.markFailed(idx);
            _ = shared.completed_jobs.fetchAdd(1, .release);
            continue;
        };
        defer out.close(shared.payload.io);

        shared.payload.extractPartition(shared.ctx, job.pidx, out, shared.tracker, idx) catch |err| {
            shared.collector.add(shared.payload.allocator, "failed to extract partition {s}: {s}", .{ job.name, @errorName(err) });
            shared.tracker.markFailed(idx);
            _ = shared.completed_jobs.fetchAdd(1, .release);
            continue;
        };

        shared.tracker.markDone(idx);
        _ = shared.completed_jobs.fetchAdd(1, .release);
    }
}

fn renderProgress(tracker: *ProgressTracker, ui: *const ui_mod.Ui, prev_lines: *usize) !void {
    if (!ui.canRenderDynamicProgress()) return;

    const out = ui.outputWriter();
    if (prev_lines.* != 0) try out.print("\x1b[{d}A", .{prev_lines.*});

    tracker.mutex.lockUncancelable(tracker.io);
    defer tracker.mutex.unlock(tracker.io);

    var done_count: usize = 0;
    var pending_count: usize = 0;
    var running_count: usize = 0;
    var failed_count: usize = 0;
    const total_count: usize = tracker.entries.len;
    var total_done_ops: usize = 0;
    var total_ops: usize = 0;

    for (tracker.entries) |entry| {
        total_done_ops += @min(entry.done_ops, entry.total_ops);
        total_ops += entry.total_ops;
        switch (entry.state) {
            .pending => pending_count += 1,
            .running => running_count += 1,
            .done => done_count += 1,
            .failed => failed_count += 1,
        }
    }

    var lines: usize = 0;
    try out.writeAll("\x1b[2K\r");
    const overall_pct: usize = if (total_ops == 0) 100 else (total_done_ops * 100) / total_ops;
    if (ui.useColor()) {
        const pct_color = percentColor(overall_pct);
        try out.print(
            "\x1b[1;36mACTIVE\x1b[0m \x1b[36m{d}\x1b[0m " ++ "\x1b[1;31mFAIL\x1b[0m \x1b[31m{d}\x1b[0m " ++ "\x1b[1;32mDONE\x1b[0m \x1b[32m{d}/{d}\x1b[0m " ++ "\x1b[1;37mPEND\x1b[0m \x1b[37m{d}\x1b[0m " ++ "\x1b[1;35mTOTAL\x1b[0m {s}{d: >3}%\x1b[0m \x1b[90m({d}/{d})\x1b[0m\n",
            .{
                running_count,
                failed_count,
                done_count,
                total_count,
                pending_count,
                pct_color,
                overall_pct,
                total_done_ops,
                total_ops,
            },
        );
    } else {
        try out.print("ACTIVE {d} FAIL {d} DONE {d}/{d} PEND {d} TOTAL {d: >3}% ({d}/{d})\n", .{
            running_count,
            failed_count,
            done_count,
            total_count,
            pending_count,
            overall_pct,
            total_done_ops,
            total_ops,
        });
    }
    lines += 1;

    for (tracker.entries) |entry| {
        if (entry.state != .running and entry.state != .failed) continue;

        try out.writeAll("\x1b[2K\r");
        const done = @min(entry.done_ops, entry.total_ops);
        const pct = if (entry.total_ops == 0) @as(u8, 100) else @as(u8, @intCast((done * 100) / entry.total_ops));
        const bar_width = 20;
        const filled = if (entry.total_ops == 0) bar_width else (done * bar_width) / entry.total_ops;
        var bar: [bar_width]u8 = undefined;
        @memset(bar[0..], '-');
        var i: usize = 0;
        while (i < filled) : (i += 1) bar[i] = '=';

        const name = if (entry.name.len > 20) entry.name[0..20] else entry.name;
        const status = switch (entry.state) {
            .running => "RUN ",
            .failed => "FAIL",
            else => unreachable,
        };
        if (ui.useColor()) {
            const status_color = switch (entry.state) {
                .running => "\x1b[36m",
                .failed => "\x1b[31m",
                else => unreachable,
            };
            const fill_color = switch (entry.state) {
                .running => "\x1b[32m",
                .failed => "\x1b[31m",
                else => unreachable,
            };
            const remain = bar[filled..];
            const done_part = bar[0..filled];
            const pct_color = percentColor(pct);
            try out.print(
                "{s}{s}\x1b[0m \x1b[1;37m{s: <20}\x1b[0m " ++ "[{s}{s}\x1b[0m\x1b[90m{s}\x1b[0m] {s}{d: >3}%\x1b[0m \x1b[90m({d}/{d})\x1b[0m\n",
                .{ status_color, status, name, fill_color, done_part, remain, pct_color, pct, done, entry.total_ops },
            );
        } else {
            try out.print("{s} {s: <20} [{s}] {d: >3}% ({d}/{d})\n", .{
                status, name, bar, pct, done, entry.total_ops,
            });
        }
        lines += 1;
    }

    while (lines < prev_lines.*) : (lines += 1) {
        try out.writeAll("\x1b[2K\r\n");
    }

    prev_lines.* = @max(lines, prev_lines.*);
    try out.flush();
}

fn percentColor(pct: usize) []const u8 {
    if (pct >= 80) return "\x1b[32m";
    if (pct >= 50) return "\x1b[33m";
    return "\x1b[31m";
}

const Header = struct {
    version: u64 = 0,
    manifest_len: u64 = 0,
    metadata_signature_len: u64 = 0,
};

fn readHeader(file: std.Io.File, io: std.Io) Error!Header {
    const magic = try readAtAlloc(std.heap.page_allocator, file, io, 0, 4);
    defer std.heap.page_allocator.free(magic);
    if (!std.mem.eql(u8, magic, "CrAU")) return error.InvalidMagic;

    const version = try readU64Be(file, io, 4);
    if (version != 2) return error.UnsupportedPayloadVersion;

    const manifest_len = try readU64Be(file, io, 12);
    const sig_len = try readU32Be(file, io, 20);

    return .{
        .version = version,
        .manifest_len = manifest_len,
        .metadata_signature_len = sig_len,
    };
}

fn readU64Be(file: std.Io.File, io: std.Io, off: u64) Error!u64 {
    var buf: [8]u8 = undefined;
    _ = file.readPositionalAll(io, &buf, off) catch return error.IoFailure;
    return std.mem.readInt(u64, &buf, .big);
}

fn readU32Be(file: std.Io.File, io: std.Io, off: u64) Error!u32 {
    var buf: [4]u8 = undefined;
    _ = file.readPositionalAll(io, &buf, off) catch return error.IoFailure;
    return std.mem.readInt(u32, &buf, .big);
}

fn readAtAlloc(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, off: u64, len_u64: u64) Error![]u8 {
    const len = std.math.cast(usize, len_u64) orelse return error.IntegerOverflow;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    _ = file.readPositionalAll(io, buf, off) catch return error.IoFailure;
    return buf;
}

fn sumExtentBytes(ctx: upb.Context, pidx: usize, oidx: usize, extent_count: usize) usize {
    var total: u64 = 0;
    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        total += ctx.dstExtentNumBlocks(pidx, oidx, eidx) * block_size;
    }
    return @intCast(total);
}

const ExtentCursor = struct {
    ctx: upb.Context,
    pidx: usize,
    oidx: usize,
    extent_count: usize,
    fw: *std.Io.File.Writer,
    extent_idx: usize = 0,
    extent_written: u64 = 0,
    total_written: u64 = 0,
    expected_total: u64 = 0,

    fn init(
        ctx: upb.Context,
        pidx: usize,
        oidx: usize,
        extent_count: usize,
        expected_total: usize,
        fw: *std.Io.File.Writer,
    ) ExtentCursor {
        return .{
            .ctx = ctx,
            .pidx = pidx,
            .oidx = oidx,
            .extent_count = extent_count,
            .fw = fw,
            .expected_total = @intCast(expected_total),
        };
    }

    fn currentExtentLen(self: ExtentCursor) u64 {
        return self.ctx.dstExtentNumBlocks(self.pidx, self.oidx, self.extent_idx) * block_size;
    }

    pub fn writeAll(self: *ExtentCursor, data: []const u8) Error!void {
        var pos: usize = 0;
        while (pos < data.len) {
            if (self.extent_idx >= self.extent_count) return error.UnexpectedBytesWritten;

            const extent_off = self.ctx.dstExtentStartBlock(self.pidx, self.oidx, self.extent_idx) * block_size;
            const extent_len = self.currentExtentLen();
            if (self.extent_written >= extent_len) {
                self.extent_idx += 1;
                self.extent_written = 0;
                continue;
            }

            const remain: usize = @intCast(extent_len - self.extent_written);
            const n = @min(remain, data.len - pos);
            self.fw.seekTo(extent_off + self.extent_written) catch return error.IoFailure;
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

    fn finish(self: *ExtentCursor) Error!void {
        if (self.total_written != self.expected_total) return error.UnexpectedBytesWritten;
        if (self.extent_idx < self.extent_count) {
            var idx = self.extent_idx;
            if (self.extent_written != 0) return error.UnexpectedBytesWritten;
            while (idx < self.extent_count) : (idx += 1) {
                if (self.ctx.dstExtentNumBlocks(self.pidx, self.oidx, idx) != 0) return error.UnexpectedBytesWritten;
            }
        }
    }
};

fn writeZeroToExtents(
    allocator: std.mem.Allocator,
    ctx: upb.Context,
    pidx: usize,
    oidx: usize,
    extent_count: usize,
    cursor: *ExtentCursor,
) Error!void {
    _ = ctx;
    _ = pidx;
    _ = oidx;
    _ = extent_count;
    const chunk = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(chunk);
    @memset(chunk, 0);

    var remaining = cursor.expected_total;
    while (remaining > 0) {
        const n: usize = @intCast(@min(remaining, chunk.len));
        try cursor.writeAll(chunk[0..n]);
        remaining -= n;
    }
}

fn containsPartition(parts: []const []const u8, name: []const u8) bool {
    for (parts) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}
