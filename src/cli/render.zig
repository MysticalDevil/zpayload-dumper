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
    const previous_rendered_lines = prev_lines.*;
    render_style.moveCursorUp(out, previous_rendered_lines) catch return error.IoFailure;

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
        const row_state: render_style.RowState = if (entry.state == .running) .running else .failed;
        render_style.writeRow(out, reporter.use_color, render_style.default_style, row_state, entry.name, done, entry.total_ops) catch return error.IoFailure;
        rendered_lines += 1;
    }

    var cleared_lines = rendered_lines;
    while (cleared_lines < previous_rendered_lines) : (cleared_lines += 1) {
        out.writeAll("\x1b[2K\r\n") catch return error.IoFailure;
    }

    // After clearing stale rows, move back to the live block bottom so the next
    // refresh only needs to travel over the currently visible lines.
    const lines_to_rewind = previous_rendered_lines -| rendered_lines;
    if (lines_to_rewind != 0) {
        render_style.moveCursorUp(out, lines_to_rewind) catch return error.IoFailure;
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

test "renderProgress moves cursor back after shrinking active rows" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const jobs = [_]progress.Job{
        .{ .pidx = 0, .name = "boot", .total_ops = 2 },
        .{ .pidx = 1, .name = "product", .total_ops = 2 },
    };

    var tracker = try progress.ProgressTracker.init(allocator, io, &jobs);
    defer tracker.deinit(allocator);

    var out_capture = std.Io.Writer.Allocating.init(allocator);
    defer out_capture.deinit();
    var err_capture = std.Io.Writer.Allocating.init(allocator);
    defer err_capture.deinit();

    const reporter = progress.Reporter.init(&out_capture.writer, &err_capture.writer, false, true);
    var prev_lines: usize = 0;

    tracker.markRunning(0);
    tracker.markRunning(1);
    try renderProgress(&tracker, &reporter, &prev_lines);

    tracker.markDone(0);
    try renderProgress(&tracker, &reporter, &prev_lines);

    const rendered = out_capture.writer.buffer[0..out_capture.writer.end];
    try std.testing.expect(std.mem.containsAtLeast(
        u8,
        rendered,
        1,
        "\x1b[2K\r\n\x1b[1A",
    ));
}
