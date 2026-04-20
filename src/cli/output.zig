const std = @import("std");
const errors = @import("../errors.zig");

const Error = errors.AppError;

pub fn makeDefaultOutputDirectory(allocator: std.mem.Allocator, io: std.Io) Error![]u8 {
    const seconds = std.Io.Timestamp.now(io, .real).toSeconds();
    if (seconds < 0) return error.TimeUnavailable;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(seconds) };
    const epoch_day = epoch_seconds.getEpochDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const year_day = epoch_day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    const year = year_day.year;
    const month = month_day.month.numeric();
    const day = month_day.day_index + 1; // day_index is 0-based
    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    var ts_buf: [32]u8 = undefined;
    const timestamp = std.fmt.bufPrint(&ts_buf, "{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
        year, month, day, hour, minute, second,
    }) catch return error.IoFailure;

    var buf: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "extracted_{s}", .{timestamp}) catch return error.IoFailure;
    return try allocator.dupe(u8, dir);
}
