const std = @import("std");
const errors = @import("../errors.zig");
const c = @import("time");

const Error = errors.AppError;

pub fn makeDefaultOutputDirectory(allocator: std.mem.Allocator) Error![]u8 {
    var now = c.time(null);
    if (now < 0) return error.TimeUnavailable;
    var tm_buf: c.struct_tm = undefined;
    if (c.localtime_r(&now, &tm_buf) == null) return error.TimeUnavailable;

    var ts_buf: [32]u8 = undefined;
    const ts_len = c.strftime(@ptrCast(&ts_buf), ts_buf.len, "%Y%m%d_%H%M%S", &tm_buf);
    if (ts_len == 0) return error.TimeUnavailable;

    var buf: [64]u8 = undefined;
    const timestamp = ts_buf[0..@intCast(ts_len)];
    const dir = std.fmt.bufPrint(&buf, "extracted_{s}", .{timestamp}) catch return error.IoFailure;
    return try allocator.dupe(u8, dir);
}
