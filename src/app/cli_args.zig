const std = @import("std");
const errors = @import("../errors.zig");
const ui_mod = @import("../cli_ui.zig");

pub const Error = errors.AppError;

pub const CliOptions = struct {
    allocator: std.mem.Allocator,
    list: bool = false,
    partitions: ?[]u8 = null,
    output: ?[]u8 = null,
    concurrency: i32 = 4,
    input: ?[]u8 = null,
    color_mode: ui_mod.ColorMode = .auto,

    pub fn init(allocator: std.mem.Allocator) CliOptions {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *CliOptions) void {
        if (self.partitions) |v| self.allocator.free(v);
        if (self.output) |v| self.allocator.free(v);
        if (self.input) |v| self.allocator.free(v);
    }
};

pub fn parseArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) Error!CliOptions {
    var opts = CliOptions.init(allocator);
    errdefer opts.deinit();

    var i: usize = 1; // argv0
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
                try help(out);
                return error.HelpDisplayed;
            }
            if (std.mem.eql(u8, arg, "--color")) {
                opts.color_mode = .always;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-color")) {
                opts.color_mode = .never;
                continue;
            }
            if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                opts.list = true;
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--partitions=")) {
                try replaceOwned(allocator, &opts.partitions, arg["--partitions=".len..]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--partitions")) {
                i += 1;
                if (i >= args.len) return usage(err_out);
                try replaceOwned(allocator, &opts.partitions, args[i]);
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--output=")) {
                try replaceOwned(allocator, &opts.output, arg["--output=".len..]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= args.len) return usage(err_out);
                try replaceOwned(allocator, &opts.output, args[i]);
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--concurrency=")) {
                opts.concurrency = std.fmt.parseInt(i32, arg["--concurrency=".len..], 10) catch return error.Usage;
                continue;
            }
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
                i += 1;
                if (i >= args.len) return usage(err_out);
                opts.concurrency = std.fmt.parseInt(i32, args[i], 10) catch return error.Usage;
                continue;
            }

            return usage(err_out);
        }

        if (opts.input == null) {
            try replaceOwned(allocator, &opts.input, arg);
        } else {
            return usage(err_out);
        }
    }

    if (opts.input == null) return usage(err_out);
    return opts;
}

fn replaceOwned(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) Error!void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, value);
}

fn usage(err_out: *std.Io.Writer) Error {
    err_out.writeAll(
        \\Usage: zpayload-dumper [options] <payload.bin|payload.zip>
        \\Try: zpayload-dumper --help
        \\
    ) catch |err| {
        std.log.warn("failed to write usage text: {}", .{err});
    };
    return error.Usage;
}

fn help(out: *std.Io.Writer) Error!void {
    out.writeAll(
        \\zpayload-dumper - Android payload.bin extractor
        \\
        \\Usage:
        \\  zpayload-dumper [options] <payload.bin|payload.zip>
        \\
        \\Options:
        \\  -h, --help                 Show this help
        \\  -l, --list                 Show partition list only
        \\  -p, --partitions <csv>     Extract selected partitions
        \\  -o, --output <dir>         Output directory
        \\  -c, --concurrency <n>      Number of parallel partition workers
        \\      --color                Force colored output
        \\      --no-color             Disable colored output
        \\
        \\Examples:
        \\  zpayload-dumper -l /path/to/payload.bin
        \\  zpayload-dumper -p boot,vendor -o out /path/to/payload.bin
        \\  zpayload-dumper /path/to/payload.zip
        \\
        \\Supported operations:
        \\  REPLACE, REPLACE_XZ, REPLACE_BZ, ZSTD, ZERO
        \\
    ) catch return error.IoFailure;
}
