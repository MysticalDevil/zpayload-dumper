const std = @import("std");

pub const ColorMode = enum {
    auto,
    always,
    never,
};

pub const ColorSource = enum {
    default_auto,
    flag,
    project_env,
    no_color_env,
    clicolor_force_env,
    clicolor_env,
};

pub const TerminalCapabilities = struct {
    stdout_is_tty: bool,
    stderr_is_tty: bool,
};

pub const ResolvedColors = struct {
    stdout: bool,
    stderr: bool,
    source: ColorSource,
};

pub const OutputFormat = enum {
    text,
    json,
};

pub const CliOptions = struct {
    allocator: std.mem.Allocator,
    list: bool = false,
    dry_run: bool = false,
    version: bool = false,
    partitions: ?[]u8 = null,
    output: ?[]u8 = null,
    old_dir: ?[]u8 = null,
    concurrency: ?i32 = null,
    input: []u8,
    color_mode: ColorMode = .auto,
    format: OutputFormat = .text,

    pub fn deinit(self: *CliOptions) void {
        if (self.partitions) |value| self.allocator.free(value);
        if (self.output) |value| self.allocator.free(value);
        if (self.old_dir) |value| self.allocator.free(value);
        self.allocator.free(self.input);
    }
};

pub const ParseResult = union(enum) {
    help: ColorMode,
    version: OutputFormat,
    run: CliOptions,
};
