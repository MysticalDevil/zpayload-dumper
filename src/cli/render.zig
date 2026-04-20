const std = @import("std");
const errors = @import("../errors.zig");
const progress = @import("../payload/progress.zig");
const utils = @import("../utils/root.zig");
const render_style = utils.render_style;

const Error = errors.AppError;

pub const sink: progress.Sink = .{
    .render_fn = renderProgress,
    .print_errors_fn = printErrors,
};

pub fn renderProgress(tracker: *progress.ProgressTracker, reporter: *const progress.Reporter, prev_lines: *usize) Error!void {
    if (!reporter.dynamic) return;

    const out = reporter.out;
    render_style.moveCursorUp(out, prev_lines.*) catch return error.IoFailure;

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

    var rendered_lines: usize = 0;
    render_style.clearLine(out) catch return error.IoFailure;
    const overall_pct: usize = if (total_ops == 0) 100 else (total_done_ops * 100) / total_ops;
    render_style.writeHeader(out, reporter.use_color, render_style.default_style, .{
        .running_count = running_count,
        .failed_count = failed_count,
        .done_count = done_count,
        .total_count = total_count,
        .pending_count = pending_count,
        .overall_pct = overall_pct,
        .total_done_ops = total_done_ops,
        .total_ops = total_ops,
    }) catch return error.IoFailure;
    rendered_lines += 1;

    for (tracker.entries) |entry| {
        if (entry.state != .running and entry.state != .failed) continue;

        render_style.clearLine(out) catch return error.IoFailure;
        const done = @min(entry.done_ops, entry.total_ops);
        const row_state: render_style.RowState = switch (entry.state) {
            .running => .running,
            .failed => .failed,
            else => unreachable,
        };
        render_style.writeRow(out, reporter.use_color, render_style.default_style, row_state, entry.name, done, entry.total_ops) catch return error.IoFailure;
        rendered_lines += 1;
    }

    var cleared_lines = rendered_lines;
    while (cleared_lines < prev_lines.*) : (cleared_lines += 1) {
        out.writeAll("\x1b[2K\r\n") catch return error.IoFailure;
    }

    prev_lines.* = rendered_lines;
    out.flush() catch return error.IoFailure;
}

pub fn printErrors(collector: *progress.ErrorCollector, reporter: *const progress.Reporter) Error!void {
    collector.mutex.lockUncancelable(collector.io);
    defer collector.mutex.unlock(collector.io);
    for (collector.messages.items) |msg| {
        reporter.fail(msg) catch return error.IoFailure;
    }
    if (collector.dropped) reporter.fail("some worker errors could not be recorded due to allocation failure") catch return error.IoFailure;
}
