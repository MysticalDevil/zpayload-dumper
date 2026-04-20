const std = @import("std");
const cli_style = @import("style.zig");
const types = @import("types.zig");
const Theme = cli_style.Theme;

pub const Ui = struct {
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    colors: types.ResolvedColors,
    terminal: types.TerminalCapabilities,

    pub fn init(
        stdout: *std.Io.Writer,
        stderr: *std.Io.Writer,
        colors: types.ResolvedColors,
        terminal: types.TerminalCapabilities,
    ) Ui {
        return .{
            .stdout = stdout,
            .stderr = stderr,
            .colors = colors,
            .terminal = terminal,
        };
    }

    pub fn stdoutWriter(self: *const Ui) *std.Io.Writer {
        return self.stdout;
    }

    pub fn stderrWriter(self: *const Ui) *std.Io.Writer {
        return self.stderr;
    }

    pub fn stdoutUsesColor(self: Ui) bool {
        return self.colors.stdout;
    }

    pub fn stderrUsesColor(self: Ui) bool {
        return self.colors.stderr;
    }

    pub fn stdoutIsTty(self: Ui) bool {
        return self.terminal.stdout_is_tty;
    }

    pub fn info(self: *const Ui, message: []const u8) !void {
        try writeTagged(self.stdout, self.colors.stdout, .info_tag, message);
    }

    pub fn success(self: *const Ui, message: []const u8) !void {
        try writeTagged(self.stdout, self.colors.stdout, .success_tag, message);
    }

    pub fn warn(self: *const Ui, message: []const u8) !void {
        try writeTagged(self.stdout, self.colors.stdout, .warn_tag, message);
    }

    pub fn fail(self: *const Ui, message: []const u8) !void {
        try writeTagged(self.stderr, self.colors.stderr, .error_tag, message);
    }
};

fn writeTagged(
    writer: *std.Io.Writer,
    use_color: bool,
    semantic: cli_style.Semantic,
    message: []const u8,
) !void {
    const theme = Theme.init(use_color);
    try writer.writeAll(theme.prefixedTag(semantic));
    try writer.writeAll(message);
    try writer.writeByte('\n');
}
