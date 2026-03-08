const std = @import("std");

pub const ColorMode = enum {
    auto,
    always,
    never,
};

pub const Ui = struct {
    out: *std.Io.Writer,
    err: *std.Io.Writer,
    color: bool,
    is_tty: bool,

    pub fn init(out: *std.Io.Writer, err: *std.Io.Writer, mode: ColorMode, auto: bool) Ui {
        const color = switch (mode) {
            .auto => auto,
            .always => true,
            .never => false,
        };
        return .{
            .out = out,
            .err = err,
            .color = color,
            .is_tty = auto,
        };
    }

    pub fn canRenderDynamicProgress(self: Ui) bool {
        return self.is_tty;
    }

    pub fn useColor(self: Ui) bool {
        return self.color;
    }

    pub fn outputWriter(self: *const Ui) *std.Io.Writer {
        return self.out;
    }

    pub fn info(self: Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.color) try self.out.writeAll("\x1b[36m[INFO]\x1b[0m ");
        if (!self.color) try self.out.writeAll("[INFO] ");
        try self.out.print(fmt, args);
        try self.out.writeByte('\n');
    }

    pub fn success(self: Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.color) try self.out.writeAll("\x1b[32m[OK]\x1b[0m ");
        if (!self.color) try self.out.writeAll("[OK] ");
        try self.out.print(fmt, args);
        try self.out.writeByte('\n');
    }

    pub fn warn(self: Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.color) try self.out.writeAll("\x1b[33m[!]\x1b[0m ");
        if (!self.color) try self.out.writeAll("[!] ");
        try self.out.print(fmt, args);
        try self.out.writeByte('\n');
    }

    pub fn fail(self: Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.color) try self.err.writeAll("\x1b[31m[x]\x1b[0m ");
        if (!self.color) try self.err.writeAll("[x] ");
        try self.err.print(fmt, args);
        try self.err.writeByte('\n');
    }
};
