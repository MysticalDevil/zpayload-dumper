const std = @import("std");
const upb = @import("ffi/upb.zig");
const compress = @import("ffi/compress.zig");
const ui_mod = @import("cli_ui.zig");

pub const block_size: u64 = 4096;

pub const Payload = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    header: Header = .{},
    metadata_size: u64 = 0,
    data_offset: u64 = 0,
    ctx: ?upb.Context = null,

    pub fn open(allocator: std.mem.Allocator, io: std.Io, filename: []const u8) !Payload {
        const file = try std.Io.Dir.cwd().openFile(io, filename, .{});
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

    pub fn init(self: *Payload) !void {
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

    pub fn printPartitionList(self: *Payload, w: *std.Io.Writer) !void {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        try w.writeAll("Found partitions:\n");
        const n = ctx.partitionCount();
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const name = ctx.partitionName(i) orelse continue;
            try w.print("  {s} ({d} bytes)\n", .{ name, ctx.partitionSize(i) });
        }
    }

    pub fn partitionCount(self: *Payload) !usize {
        const ctx = self.ctx orelse return error.ManifestNotInitialized;
        return ctx.partitionCount();
    }

    pub fn extractAll(self: *Payload, output_dir: []const u8, concurrency: usize, ui: *const ui_mod.Ui) !void {
        return self.extractSelected(output_dir, &.{}, concurrency, ui);
    }

    pub fn extractSelected(
        self: *Payload,
        output_dir: []const u8,
        selected: []const []const u8,
        concurrency: usize,
        ui: *const ui_mod.Ui,
    ) !void {
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
            thread.* = try std.Thread.spawn(.{}, workerMain, .{&shared});
        }

        var prev_lines: usize = 0;
        while (completed_jobs.load(.acquire) < jobs.items.len) {
            renderProgress(&tracker, ui, &prev_lines) catch |err| {
                std.log.warn("failed to render progress: {}", .{err});
            };
            _ = try self.io.sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake);
        }

        for (threads) |thread| thread.join();

        renderProgress(&tracker, ui, &prev_lines) catch |err| {
            std.log.warn("failed to render final progress: {}", .{err});
        };

        if (collector.hasErrors()) {
            try collector.print(ui);
            return error.ExtractFailed;
        }
    }

    fn extractPartition(self: *Payload, ctx: upb.Context, pidx: usize, out: std.Io.File, tracker: *ProgressTracker, tracker_idx: usize) !void {
        var writer_buf: [64 * 1024]u8 = undefined;
        var fw = out.writer(self.io, &writer_buf);
        errdefer fw.flush() catch |err| {
            std.log.warn("failed to flush output writer on error path: {}", .{err});
        };

        const op_count = ctx.operationCount(pidx);
        var oidx: usize = 0;
        while (oidx < op_count) : (oidx += 1) {
            const extent_count = ctx.dstExtentCount(pidx, oidx);
            if (extent_count == 0) return error.InvalidDstExtents;

            const blob_len_u64 = ctx.operationDataLength(pidx, oidx);
            const blob_off_u64 = ctx.operationDataOffset(pidx, oidx);
            const blob_abs = self.data_offset + blob_off_u64;
            const blob = try readAtAlloc(self.allocator, self.file, self.io, blob_abs, blob_len_u64);
            defer self.allocator.free(blob);

            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(blob, &hash, .{});

            const expected_uncompressed = sumExtentBytes(ctx, pidx, oidx, extent_count);
            const op_type = ctx.operationType(pidx, oidx) orelse return error.UnhandledOperationType;

            switch (op_type) {
                .replace => {
                    if (blob.len != expected_uncompressed) return error.UnexpectedBytesWritten;
                    try copyToExtents(ctx, pidx, oidx, extent_count, &fw, blob);
                },
                .replace_xz => {
                    const out_buf = try compress.decompressXz(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, &fw, out_buf);
                },
                .replace_bz => {
                    const out_buf = try compress.decompressBz2(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, &fw, out_buf);
                },
                .zstd => {
                    const out_buf = try compress.decompressZstd(self.allocator, blob, expected_uncompressed);
                    defer self.allocator.free(out_buf);
                    try copyToExtents(ctx, pidx, oidx, extent_count, &fw, out_buf);
                },
                .zero => {
                    try writeZeroToExtents(self.allocator, ctx, pidx, oidx, extent_count, &fw);
                },
                else => return error.UnhandledOperationType,
            }

            if (ctx.operationSha256(pidx, oidx)) |expected| {
                if (!std.mem.eql(u8, expected, hash[0..])) return error.ChecksumMismatch;
            }
            tracker.updateOps(tracker_idx, oidx + 1);
        }
        try fw.flush();
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
    }

    fn markDone(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .done;
        self.entries[idx].done_ops = self.entries[idx].total_ops;
    }

    fn markFailed(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .failed;
    }

    fn updateOps(self: *ProgressTracker, idx: usize, done_ops: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].done_ops = done_ops;
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

    fn print(self: *ErrorCollector, ui: *const ui_mod.Ui) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.messages.items) |msg| try ui.fail("{s}", .{msg});
        if (self.dropped) try ui.fail("some worker errors could not be recorded due to allocation failure", .{});
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

    var lines: usize = 0;
    for (tracker.entries) |entry| {
        try out.writeAll("\x1b[2K\r");

        const done = @min(entry.done_ops, entry.total_ops);
        const pct = if (entry.total_ops == 0) @as(u8, 100) else @as(u8, @intCast((done * 100) / entry.total_ops));
        const bar_width = 24;
        const filled = if (entry.total_ops == 0) bar_width else (done * bar_width) / entry.total_ops;
        var bar: [bar_width]u8 = undefined;
        @memset(bar[0..], '-');
        var i: usize = 0;
        while (i < filled) : (i += 1) bar[i] = '=';

        const status = switch (entry.state) {
            .pending => "PEND",
            .running => "RUN ",
            .done => "DONE",
            .failed => "FAIL",
        };
        if (ui.useColor()) {
            const color = switch (entry.state) {
                .pending => "\x1b[37m",
                .running => "\x1b[36m",
                .done => "\x1b[32m",
                .failed => "\x1b[31m",
            };
            try out.print("{s}{s}\x1b[0m {s: <20} [{s}] {d: >3}% ({d}/{d})\n", .{
                color,
                status,
                entry.name,
                bar,
                pct,
                done,
                entry.total_ops,
            });
        } else {
            try out.print("{s} {s: <20} [{s}] {d: >3}% ({d}/{d})\n", .{
                status,
                entry.name,
                bar,
                pct,
                done,
                entry.total_ops,
            });
        }
        lines += 1;
    }

    prev_lines.* = lines;
    try out.flush();
}

const Header = struct {
    version: u64 = 0,
    manifest_len: u64 = 0,
    metadata_signature_len: u64 = 0,
};

fn readHeader(file: std.Io.File, io: std.Io) !Header {
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

fn readU64Be(file: std.Io.File, io: std.Io, off: u64) !u64 {
    var buf: [8]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, off);
    return std.mem.readInt(u64, &buf, .big);
}

fn readU32Be(file: std.Io.File, io: std.Io, off: u64) !u32 {
    var buf: [4]u8 = undefined;
    _ = try file.readPositionalAll(io, &buf, off);
    return std.mem.readInt(u32, &buf, .big);
}

fn readAtAlloc(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io, off: u64, len_u64: u64) ![]u8 {
    const len = std.math.cast(usize, len_u64) orelse return error.IntegerOverflow;
    const buf = try allocator.alloc(u8, len);
    errdefer allocator.free(buf);
    _ = try file.readPositionalAll(io, buf, off);
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

fn copyToExtents(
    ctx: upb.Context,
    pidx: usize,
    oidx: usize,
    extent_count: usize,
    fw: *std.Io.File.Writer,
    data: []const u8,
) !void {
    var read_off: usize = 0;
    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        const extent_off = ctx.dstExtentStartBlock(pidx, oidx, eidx) * block_size;
        const extent_len_u64 = ctx.dstExtentNumBlocks(pidx, oidx, eidx) * block_size;
        const extent_len: usize = @intCast(extent_len_u64);
        if (read_off + extent_len > data.len) return error.UnexpectedBytesWritten;
        try fw.seekTo(extent_off);
        try fw.interface.writeAll(data[read_off .. read_off + extent_len]);
        read_off += extent_len;
    }
    if (read_off != data.len) return error.UnexpectedBytesWritten;
}

fn writeZeroToExtents(
    allocator: std.mem.Allocator,
    ctx: upb.Context,
    pidx: usize,
    oidx: usize,
    extent_count: usize,
    fw: *std.Io.File.Writer,
) !void {
    const chunk = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(chunk);
    @memset(chunk, 0);

    var eidx: usize = 0;
    while (eidx < extent_count) : (eidx += 1) {
        const extent_off = ctx.dstExtentStartBlock(pidx, oidx, eidx) * block_size;
        var remaining: u64 = ctx.dstExtentNumBlocks(pidx, oidx, eidx) * block_size;
        var write_off: u64 = 0;
        while (remaining > 0) {
            const n: usize = @intCast(@min(remaining, chunk.len));
            try fw.seekTo(extent_off + write_off);
            try fw.interface.writeAll(chunk[0..n]);
            remaining -= n;
            write_off += n;
        }
    }

    try fw.flush();
}

fn containsPartition(parts: []const []const u8, name: []const u8) bool {
    for (parts) |part| {
        if (std.mem.eql(u8, part, name)) return true;
    }
    return false;
}
