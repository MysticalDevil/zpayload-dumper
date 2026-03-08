const std = @import("std");
const errors = @import("../errors.zig");
const ui_mod = @import("../command_line_ui.zig");
const render_style = @import("../utils/render_style.zig");

pub const Error = errors.SystemError;

pub const Job = struct {
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

pub const ProgressTracker = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    dirty: std.atomic.Value(bool) = .init(true),
    entries: []PartitionProgress,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, jobs: []const Job) !ProgressTracker {
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

    pub fn deinit(self: *ProgressTracker, allocator: std.mem.Allocator) void {
        allocator.free(self.entries);
    }

    pub fn markRunning(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .running;
        _ = self.dirty.swap(true, .release);
    }

    pub fn markDone(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .done;
        self.entries[idx].done_ops = self.entries[idx].total_ops;
        _ = self.dirty.swap(true, .release);
    }

    pub fn markFailed(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .failed;
        _ = self.dirty.swap(true, .release);
    }

    pub fn updateOps(self: *ProgressTracker, idx: usize, done_ops: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entries[idx].done_ops != done_ops) {
            self.entries[idx].done_ops = done_ops;
            _ = self.dirty.swap(true, .release);
        }
    }

    pub fn consumeDirty(self: *ProgressTracker) bool {
        return self.dirty.swap(false, .acq_rel);
    }
};

pub const ErrorCollector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    messages: std.array_list.Managed([]u8),
    dropped: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ErrorCollector {
        return .{
            .allocator = allocator,
            .io = io,
            .messages = std.array_list.Managed([]u8).init(allocator),
        };
    }

    pub fn deinit(self: *ErrorCollector) void {
        for (self.messages.items) |msg| self.allocator.free(msg);
        self.messages.deinit();
    }

    pub fn hasErrors(self: *ErrorCollector) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.messages.items.len != 0 or self.dropped;
    }

    pub fn add(self: *ErrorCollector, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch {
            self.mutex.lockUncancelable(self.io);
            self.dropped = true;
            self.mutex.unlock(self.io);
            return;
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.messages.append(msg) catch {
            self.allocator.free(msg);
            self.dropped = true;
        };
    }

    pub fn print(self: *ErrorCollector, ui: *const ui_mod.Ui) Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        for (self.messages.items) |msg| {
            ui.fail("{s}", .{msg}) catch return error.IoFailure;
        }
        if (self.dropped) ui.fail("some worker errors could not be recorded due to allocation failure", .{}) catch return error.IoFailure;
    }
};

pub fn renderProgress(tracker: *ProgressTracker, ui: *const ui_mod.Ui, prev_lines: *usize) !void {
    if (!ui.canRenderDynamicProgress()) return;

    const out = ui.outputWriter();
    try render_style.moveCursorUp(out, prev_lines.*);

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
    try render_style.clearLine(out);
    const overall_pct: usize = if (total_ops == 0) 100 else (total_done_ops * 100) / total_ops;
    try render_style.writeHeader(out, ui.useColor(), render_style.default_style, .{
        .running_count = running_count,
        .failed_count = failed_count,
        .done_count = done_count,
        .total_count = total_count,
        .pending_count = pending_count,
        .overall_pct = overall_pct,
        .total_done_ops = total_done_ops,
        .total_ops = total_ops,
    });
    lines += 1;

    for (tracker.entries) |entry| {
        if (entry.state != .running and entry.state != .failed) continue;

        try render_style.clearLine(out);
        const done = @min(entry.done_ops, entry.total_ops);
        const row_state: render_style.RowState = switch (entry.state) {
            .running => .running,
            .failed => .failed,
            else => unreachable,
        };
        try render_style.writeRow(out, ui.useColor(), render_style.default_style, row_state, entry.name, done, entry.total_ops);
        lines += 1;
    }

    while (lines < prev_lines.*) : (lines += 1) {
        try out.writeAll("\x1b[2K\r\n");
    }

    prev_lines.* = @max(lines, prev_lines.*);
    try out.flush();
}
