const std = @import("std");
const errors = @import("../errors.zig");
const types = @import("types.zig");

const Error = errors.AppError;

pub const EnvColors = struct {
    zpayload_color: ?[]const u8 = null,
    no_color: ?[]const u8 = null,
    clicolor: ?[]const u8 = null,
    clicolor_force: ?[]const u8 = null,
};

pub fn parseArgs(
    allocator: std.mem.Allocator,
    env_colors: EnvColors,
    args: []const []const u8,
) Error!types.ParseResult {
    var options = types.CliOptions{
        .allocator = allocator,
        .input = undefined,
        .color_mode = resolveEnvColorMode(env_colors).mode,
    };
    var has_input = false;
    var i: usize = 1;

    errdefer if (has_input) {
        allocator.free(options.input);
        if (options.partitions) |value| allocator.free(value);
        if (options.output) |value| allocator.free(value);
    };

    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            return .{ .help = options.color_mode };
        }

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "--color")) {
                options.color_mode = .always;
                continue;
            }
            if (std.mem.eql(u8, arg, "--no-color")) {
                options.color_mode = .never;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--color=")) {
                options.color_mode = parseColorMode(arg["--color=".len..]) orelse return error.Usage;
                continue;
            }
            if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                options.list = true;
                continue;
            }
            if (std.mem.eql(u8, arg, "--dry-run")) {
                options.dry_run = true;
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--partitions=")) {
                try replaceOwned(allocator, &options.partitions, arg["--partitions=".len..]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--partitions")) {
                i += 1;
                if (i >= args.len) return error.Usage;
                try replaceOwned(allocator, &options.partitions, args[i]);
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--output=")) {
                try replaceOwned(allocator, &options.output, arg["--output=".len..]);
                continue;
            }
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= args.len) return error.Usage;
                try replaceOwned(allocator, &options.output, args[i]);
                continue;
            }
            if (std.mem.startsWith(u8, arg, "--concurrency=")) {
                options.concurrency = std.fmt.parseInt(i32, arg["--concurrency=".len..], 10) catch return error.Usage;
                continue;
            }
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
                i += 1;
                if (i >= args.len) return error.Usage;
                options.concurrency = std.fmt.parseInt(i32, args[i], 10) catch return error.Usage;
                continue;
            }
            return error.Usage;
        }

        if (has_input) return error.Usage;
        options.input = try allocator.dupe(u8, arg);
        has_input = true;
    }

    if (!has_input) return error.Usage;
    return .{ .run = options };
}

pub fn resolveColors(mode: types.ColorMode, terminal: types.TerminalCapabilities) types.ResolvedColors {
    const stdout_color = switch (mode) {
        .auto => terminal.stdout_is_tty,
        .always => true,
        .never => false,
    };
    const stderr_color = switch (mode) {
        .auto => terminal.stderr_is_tty,
        .always => true,
        .never => false,
    };
    return .{
        .stdout = stdout_color,
        .stderr = stderr_color,
        .source = switch (mode) {
            .auto => .default_auto,
            .always => .flag,
            .never => .flag,
        },
    };
}

const EnvColor = struct {
    mode: types.ColorMode,
    source: types.ColorSource,
};

fn resolveEnvColorMode(env_colors: EnvColors) EnvColor {
    if (env_colors.zpayload_color) |value| {
        if (parseColorMode(value)) |mode| {
            return .{
                .mode = mode,
                .source = .project_env,
            };
        }
    }
    if (envTruthy(env_colors.clicolor_force)) {
        return .{
            .mode = .always,
            .source = .clicolor_force_env,
        };
    }
    if (env_colors.no_color != null) {
        return .{
            .mode = .never,
            .source = .no_color_env,
        };
    }
    if (env_colors.clicolor) |value| {
        if (std.mem.eql(u8, value, "0")) {
            return .{
                .mode = .never,
                .source = .clicolor_env,
            };
        }
    }
    return .{
        .mode = .auto,
        .source = .default_auto,
    };
}

fn envTruthy(value: ?[]const u8) bool {
    const text = value orelse return false;
    if (text.len == 0) return false;
    return !std.mem.eql(u8, text, "0");
}

fn parseColorMode(text: []const u8) ?types.ColorMode {
    if (std.mem.eql(u8, text, "auto")) return .auto;
    if (std.mem.eql(u8, text, "always")) return .always;
    if (std.mem.eql(u8, text, "never")) return .never;
    return null;
}

fn replaceOwned(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, value);
}

test "parseArgs enables dry-run mode" {
    const allocator = std.testing.allocator;
    const args = [_][]const u8{
        "zpayload-dumper",
        "--dry-run",
        "-p",
        "boot,vendor",
        "payload.bin",
    };

    const result = try parseArgs(allocator, .{}, &args);
    switch (result) {
        .help => try std.testing.expect(false),
        .run => |options| {
            defer {
                var owned = options;
                owned.deinit();
            }
            try std.testing.expect(options.dry_run);
            try std.testing.expect(options.partitions != null);
            try std.testing.expectEqualStrings("payload.bin", options.input);
        },
    }
}
