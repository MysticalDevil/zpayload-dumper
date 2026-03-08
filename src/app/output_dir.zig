const std = @import("std");
const errors = @import("../errors.zig");
const c = @cImport({
    @cInclude("time.h");
});

const Error = errors.AppError;

pub fn makeDefaultOutputDirectory(allocator: std.mem.Allocator, io: std.Io) Error![]u8 {
    _ = io;
    var now = c.time(null);
    if (now < 0) return error.TimeUnavailable;
    var tm_buf: c.struct_tm = undefined;
    if (c.localtime_r(&now, &tm_buf) == null) return error.TimeUnavailable;

    const year: i32 = tm_buf.tm_year + 1900;
    const month: i32 = tm_buf.tm_mon + 1;
    const day: i32 = tm_buf.tm_mday;
    const hour: i32 = tm_buf.tm_hour;
    const minute: i32 = tm_buf.tm_min;
    const second: i32 = tm_buf.tm_sec;

    var buf: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "extracted_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
        year, month, day, hour, minute, second,
    }) catch return error.IoFailure;
    return try allocator.dupe(u8, dir);
}
