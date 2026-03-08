const std = @import("std");

pub const RowState = enum {
    running,
    failed,
};

pub const HeaderStats = struct {
    running_count: usize,
    failed_count: usize,
    done_count: usize,
    total_count: usize,
    pending_count: usize,
    overall_pct: usize,
    total_done_ops: usize,
    total_ops: usize,
};

pub const Style = struct {
    bar_width: usize = 20,
    bar_fill: u8 = '=',
    bar_empty: u8 = '-',
    label_active: []const u8 = "ACTIVE",
    label_fail: []const u8 = "FAIL",
    label_done: []const u8 = "DONE",
    label_pending: []const u8 = "PEND",
    label_total: []const u8 = "TOTAL",
    label_running: []const u8 = "RUN ",
    label_failed: []const u8 = "FAIL",
    label_name_width: usize = 20,
};

pub const default_style = Style{};

pub fn moveCursorUp(out: *std.Io.Writer, lines: usize) !void {
    if (lines != 0) try out.print("\x1b[{d}A", .{lines});
}

pub fn clearLine(out: *std.Io.Writer) !void {
    try out.writeAll("\x1b[2K\r");
}

pub fn writeHeader(out: *std.Io.Writer, use_color: bool, style: Style, stats: HeaderStats) !void {
    if (use_color) {
        const pct_color = percentColor(stats.overall_pct);
        try out.print(
            "\x1b[1;36m{s}\x1b[0m \x1b[36m{d}\x1b[0m \x1b[1;31m{s}\x1b[0m \x1b[31m{d}\x1b[0m \x1b[1;32m{s}\x1b[0m \x1b[32m{d}/{d}\x1b[0m \x1b[1;37m{s}\x1b[0m \x1b[37m{d}\x1b[0m \x1b[1;35m{s}\x1b[0m {s}{d: >3}%\x1b[0m \x1b[90m({d}/{d})\x1b[0m\n",
            .{
                style.label_active,
                stats.running_count,
                style.label_fail,
                stats.failed_count,
                style.label_done,
                stats.done_count,
                stats.total_count,
                style.label_pending,
                stats.pending_count,
                style.label_total,
                pct_color,
                stats.overall_pct,
                stats.total_done_ops,
                stats.total_ops,
            },
        );
    } else {
        try out.print("{s} {d} {s} {d} {s} {d}/{d} {s} {d} {s} {d: >3}% ({d}/{d})\n", .{
            style.label_active,
            stats.running_count,
            style.label_fail,
            stats.failed_count,
            style.label_done,
            stats.done_count,
            stats.total_count,
            style.label_pending,
            stats.pending_count,
            style.label_total,
            stats.overall_pct,
            stats.total_done_ops,
            stats.total_ops,
        });
    }
}

pub fn writeRow(
    out: *std.Io.Writer,
    use_color: bool,
    style: Style,
    state: RowState,
    name: []const u8,
    done: usize,
    total: usize,
) !void {
    const pct = if (total == 0) @as(u8, 100) else @as(u8, @intCast((done * 100) / total));
    const filled = if (total == 0) style.bar_width else (done * style.bar_width) / total;
    var bar: [64]u8 = undefined;
    const bar_slice = bar[0..style.bar_width];
    @memset(bar_slice, style.bar_empty);
    var i: usize = 0;
    while (i < filled) : (i += 1) bar_slice[i] = style.bar_fill;

    const clipped_name = if (name.len > style.label_name_width) name[0..style.label_name_width] else name;
    const status = switch (state) {
        .running => style.label_running,
        .failed => style.label_failed,
    };

    if (use_color) {
        const status_color = switch (state) {
            .running => "\x1b[36m",
            .failed => "\x1b[31m",
        };
        const fill_color = switch (state) {
            .running => "\x1b[32m",
            .failed => "\x1b[31m",
        };
        const remain = bar_slice[filled..];
        const done_part = bar_slice[0..filled];
        const pct_color = percentColor(pct);
        try out.print(
            "{s}{s}\x1b[0m \x1b[1;37m{s: <20}\x1b[0m [{s}{s}\x1b[0m\x1b[90m{s}\x1b[0m] {s}{d: >3}%\x1b[0m \x1b[90m({d}/{d})\x1b[0m\n",
            .{ status_color, status, clipped_name, fill_color, done_part, remain, pct_color, pct, done, total },
        );
    } else {
        try out.print("{s} {s: <20} [{s}] {d: >3}% ({d}/{d})\n", .{
            status, clipped_name, bar_slice, pct, done, total,
        });
    }
}

fn percentColor(pct: usize) []const u8 {
    if (pct >= 80) return "\x1b[32m";
    if (pct >= 50) return "\x1b[33m";
    return "\x1b[31m";
}
