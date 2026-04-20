const std = @import("std");
const errors = @import("errors.zig");
const app = @import("root.zig");
const cli = app.cli;
const payload = app.payload;

const Error = errors.AppError;

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.Usage => std.process.exit(2),
        else => {
            const io = init.io;
            var stderr_file = std.Io.File.stderr();
            var stderr = stderr_file.writer(io, &.{});
            const detail = errors.detail(err);
            stderr.interface.print("error[{s}]: {s}\n", .{ detail.stable_name, cli.messages.userMessage(err) }) catch std.process.exit(1);
            std.process.exit(1);
        },
    };
}

fn run(init: std.process.Init) Error!void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_file = std.Io.File.stderr();
    var stdout_file = std.Io.File.stdout();
    var stderr = stderr_file.writer(io, &.{});
    var stdout = stdout_file.writer(io, &.{});

    const argv = init.minimal.args.toSlice(arena) catch return error.IoFailure;
    const env_colors = cli.parse.EnvColors{
        .zpayload_color = init.environ_map.get("ZPAYLOAD_COLOR"),
        .no_color = init.environ_map.get("NO_COLOR"),
        .clicolor = init.environ_map.get("CLICOLOR"),
        .clicolor_force = init.environ_map.get("CLICOLOR_FORCE"),
    };
    const parse_result = cli.parse.parseArgs(gpa, env_colors, argv) catch |err| switch (err) {
        error.Usage => {
            cli.help.renderUsage(&stderr.interface) catch return error.IoFailure;
            return error.Usage;
        },
        else => return err,
    };
    const terminal = cli.types.TerminalCapabilities{
        .stdout_is_tty = stdout_file.isTty(io) catch false,
        .stderr_is_tty = stderr_file.isTty(io) catch false,
    };

    switch (parse_result) {
        .help => |color_mode| {
            const colors = cli.parse.resolveColors(color_mode, terminal);
            cli.help.renderFull(&stdout.interface, colors.stdout) catch return error.IoFailure;
        },
        .run => |options_value| {
            var options = options_value;
            defer options.deinit();
            const colors = cli.parse.resolveColors(options.color_mode, terminal);
            const ui = cli.ui.Ui.init(&stdout.interface, &stderr.interface, colors);
            const reporter = payload.Reporter{
                .out = &stdout.interface,
                .err = &stderr.interface,
                .use_color = colors.stdout,
                .dynamic = terminal.stdout_is_tty,
            };
            cli.runner.run(init, &options, &ui, &reporter) catch |err| switch (err) {
                error.Usage => {
                    cli.help.renderUsage(&stderr.interface) catch return error.IoFailure;
                    return error.Usage;
                },
                else => return err,
            };
        },
    }
}
