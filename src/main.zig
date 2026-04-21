const std = @import("std");
const errors = @import("errors.zig");
const app = @import("root.zig");
const cli = app.cli;
const payload = app.payload;

const Error = errors.AppError;

fn suggestionForError(err: Error) ?[]const u8 {
    return switch (err) {
        error.InvalidConcurrency => "zpayload-dumper --help",
        error.InvalidZipArchive => "verify the file is a valid zip archive",
        error.PayloadNotFoundInZip => "ensure the zip archive contains payload.bin",
        error.InvalidMagic => "ensure the file is a valid payload.bin (expected CrAU header)",
        error.UnsupportedPayloadVersion => "ensure the payload uses version 2",
        error.InsufficientDiskSpace => "specify a different output directory with -o or free up disk space",
        error.IoFailure => "verify the file path is correct and the file is readable",
        error.OutOfMemory => "close other applications or reduce concurrency with -c",
        error.TimeUnavailable => "check system clock configuration",
        error.DecodeFailed => "ensure the payload.bin is not corrupted",
        error.ChecksumMismatch => "the payload may be corrupted, try re-downloading",
        else => "zpayload-dumper --help for usage information",
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stderr_file = std.Io.File.stderr();
    var stderr = stderr_file.writer(io, &.{});

    run(init, &stderr.interface) catch |err| switch (err) {
        error.Usage => std.process.exit(2),
        else => {
            const detail = errors.detail(err);
            stderr.interface.print("error[{s}]: {s}\n", .{ detail.stable_name, cli.messages.userMessage(err) }) catch std.process.exit(1);
            if (suggestionForError(err)) |suggestion| {
                stderr.interface.print("Try: {s}\n", .{suggestion}) catch std.process.exit(1);
            }
            std.process.exit(1);
        },
    };
}

fn run(init: std.process.Init, main_stderr: *std.Io.Writer) Error!void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_file = std.Io.File.stdout();
    var stdout = stdout_file.writer(io, &.{});

    var stderr_file = std.Io.File.stderr();
    const terminal = cli.types.TerminalCapabilities{
        .stdout_is_tty = stdout_file.isTty(io) catch false,
        .stderr_is_tty = stderr_file.isTty(io) catch false,
    };

    const argv = init.minimal.args.toSlice(arena) catch return error.IoFailure;
    const env_colors = cli.parse.EnvColors{
        .zpayload_color = init.environ_map.get("ZPAYLOAD_COLOR"),
        .no_color = init.environ_map.get("NO_COLOR"),
        .clicolor = init.environ_map.get("CLICOLOR"),
        .clicolor_force = init.environ_map.get("CLICOLOR_FORCE"),
    };
    const parse_result = cli.parse.parseArgs(gpa, env_colors, argv) catch |err| switch (err) {
        error.Usage => {
            const env_color = cli.parse.resolveEnvColorMode(env_colors);
            const help_colors = cli.parse.resolveColors(env_color.mode, terminal);
            cli.help.renderUsage(&stdout.interface, help_colors.stdout) catch return error.IoFailure;
            return error.Usage;
        },
        else => return err,
    };

    switch (parse_result) {
        .help => |color_mode| {
            const colors = cli.parse.resolveColors(color_mode, terminal);
            cli.help.renderFull(&stdout.interface, colors.stdout) catch return error.IoFailure;
        },
        .version => {
            const build_options = @import("build_options");
            stdout.interface.print("{s}\n", .{build_options.version}) catch return error.IoFailure;
        },
        .run => |options_value| {
            var options = options_value;
            defer options.deinit();
            const colors = cli.parse.resolveColors(options.color_mode, terminal);
            const ui = cli.ui.Ui.init(&stdout.interface, main_stderr, colors);
            const reporter = payload.Reporter{
                .out = &stdout.interface,
                .err = main_stderr,
                .use_color = colors.stdout,
                .dynamic = terminal.stdout_is_tty,
            };
            cli.runner.run(init, &options, &ui, &reporter) catch |err| switch (err) {
                error.Usage => {
                    const help_colors = cli.parse.resolveColors(options.color_mode, terminal);
                    cli.help.renderUsage(&stdout.interface, help_colors.stdout) catch return error.IoFailure;
                    return error.Usage;
                },
                else => return err,
            };
        },
    }
}
