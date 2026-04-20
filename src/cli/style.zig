const std = @import("std");

pub const Semantic = enum {
    title,
    command,
    algorithm,
    section,
    usage_hint,
    literal,
    placeholder,
    context,
    context_value,
    note,
    info_tag,
    success_tag,
    warn_tag,
    error_tag,
};

pub const Theme = struct {
    use_color: bool,

    pub fn init(use_color: bool) Theme {
        return .{ .use_color = use_color };
    }

    pub fn write(self: Theme, writer: *std.Io.Writer, semantic: Semantic, text: []const u8) !void {
        if (!self.use_color) {
            try writer.writeAll(text);
            return;
        }
        try writer.writeAll(startCode(semantic));
        try writer.writeAll(text);
        try writer.writeAll(resetCode());
    }

    pub fn prefixedTag(self: Theme, semantic: Semantic) []const u8 {
        return if (self.use_color) coloredTag(semantic) else plainTag(semantic);
    }

    fn startCode(semantic: Semantic) []const u8 {
        return switch (semantic) {
            .title => "\x1b[1;36m",
            .command => "\x1b[1;4;35m",
            .algorithm => "\x1b[1;32m",
            .section => "\x1b[1;33m",
            .usage_hint => "\x1b[1;33m",
            .literal => "\x1b[1;94m",
            .placeholder => "\x1b[96m",
            .context => "\x1b[2m",
            .context_value => "\x1b[1;2m",
            .note => "\x1b[36m",
            .info_tag => "\x1b[1;36m",
            .success_tag => "\x1b[1;32m",
            .warn_tag => "\x1b[1;33m",
            .error_tag => "\x1b[1;31m",
        };
    }

    fn coloredTag(semantic: Semantic) []const u8 {
        return switch (semantic) {
            .info_tag => "\x1b[1;36m[INFO]\x1b[0m ",
            .success_tag => "\x1b[1;32m[OK]\x1b[0m ",
            .warn_tag => "\x1b[1;33m[!]\x1b[0m ",
            .error_tag => "\x1b[1;31m[x]\x1b[0m ",
            else => plainTag(semantic),
        };
    }

    fn plainTag(semantic: Semantic) []const u8 {
        return switch (semantic) {
            .info_tag => "[INFO] ",
            .success_tag => "[OK] ",
            .warn_tag => "[!] ",
            .error_tag => "[x] ",
            else => "",
        };
    }

    fn resetCode() []const u8 {
        return "\x1b[0m";
    }
};
