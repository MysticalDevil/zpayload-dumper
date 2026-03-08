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

    pub fn init(out: *std.Io.Writer, err: *std.Io.Writer, mode: ColorMode) Ui {
        const auto = std.fs.File.stdout().isTty();
        const color = switch (mode) {
            .auto => auto,
            .always => true,
            .never => false,
        };
        return .{
            .out = out,
            .err = err,
            .color = color,
        };
    }

    pub fn info(self: Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.color) try self.out.writeAll("\x1b[36m[i]\x1b[0m ");
        if (!self.color) try self.out.writeAll("[i] ");
        try self.out.print(fmt, args);
        try self.out.writeByte('\n');
    }

    pub fn success(self: Ui, comptime fmt: []const u8, args: anytype) !void {
        if (self.color) try self.out.writeAll("\x1b[32m[ok]\x1b[0m ");
        if (!self.color) try self.out.writeAll("[ok] ");
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
