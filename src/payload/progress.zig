const std = @import("std");
const errors = @import("../errors.zig");

pub const Error = errors.AppError;

pub const Reporter = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    use_color: bool,
    dynamic: bool,

    pub fn init(out: *std.Io.Writer, err: *std.Io.Writer, use_color: bool, dynamic: bool) Reporter {
        return .{
            .out = out,
            .err = err,
            .use_color = use_color,
            .dynamic = dynamic,
        };
    }

    pub fn fail(self: *const Reporter, message: []const u8) Error!void {
        if (self.use_color) {
            self.err.writeAll("\x1b[31m[x]\x1b[0m ") catch return error.IoFailure;
        } else {
            self.err.writeAll("[x] ") catch return error.IoFailure;
        }
        self.err.writeAll(message) catch return error.IoFailure;
        self.err.writeByte('\n') catch return error.IoFailure;
    }
};

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
        if (self.dirty.swap(true, .release)) {}
    }

    pub fn markDone(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .done;
        self.entries[idx].done_ops = self.entries[idx].total_ops;
        if (self.dirty.swap(true, .release)) {}
    }

    pub fn markFailed(self: *ProgressTracker, idx: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.entries[idx].state = .failed;
        if (self.dirty.swap(true, .release)) {}
    }

    pub fn updateOps(self: *ProgressTracker, idx: usize, done_ops: usize) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.entries[idx].done_ops != done_ops) {
            self.entries[idx].done_ops = done_ops;
            if (self.dirty.swap(true, .release)) {}
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

    pub fn addOwned(self: *ErrorCollector, msg: []u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.messages.append(msg) catch {
            self.allocator.free(msg);
            self.dropped = true;
        };
    }
};

pub const Sink = struct {
    render_fn: *const fn (tracker: *ProgressTracker, reporter: *const Reporter, prev_lines: *usize) Error!void,
    print_errors_fn: *const fn (collector: *ErrorCollector, reporter: *const Reporter) Error!void,

    pub const noop: Sink = .{
        .render_fn = noopRender,
        .print_errors_fn = noopPrintErrors,
    };

    fn noopRender(_: *ProgressTracker, _: *const Reporter, _: *usize) Error!void {}
    fn noopPrintErrors(_: *ErrorCollector, _: *const Reporter) Error!void {}
};
