const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .err,
};

comptime {
    _ = @import("integration_suite.zig");
}
