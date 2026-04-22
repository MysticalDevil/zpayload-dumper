const std = @import("std");
const cli_style = @import("style.zig");
const Theme = cli_style.Theme;

const Layout = struct {
    const section_indent = 2;
    const continuation_indent = 6;
    const option_column = 34;
    const example_indent = 2;

    fn writeSectionIndent(writer: *std.Io.Writer) !void {
        try writeSpaces(writer, section_indent);
    }

    fn writeContinuationIndent(writer: *std.Io.Writer) !void {
        try writeSpaces(writer, continuation_indent);
    }

    fn writeBlankLine(writer: *std.Io.Writer) !void {
        try writer.writeByte('\n');
    }

    fn optionPadLen(current_len: usize) usize {
        if (current_len >= option_column) return 1;
        return option_column - current_len;
    }
};

pub fn renderUsage(writer: *std.Io.Writer, use_color: bool) !void {
    const theme = Theme.init(use_color);
    try theme.write(writer, .usage_hint, "Usage:");
    try writer.writeAll(" zpayload-dumper [options] ");
    try theme.write(writer, .placeholder, "<payload.bin|ota.zip>");
    try writer.writeByte('\n');
    try theme.write(writer, .usage_hint, "Try:");
    try writer.writeByte(' ');
    try theme.write(writer, .literal, "zpayload-dumper");
    try writer.writeByte(' ');
    try theme.write(writer, .literal, "--help");
    try Layout.writeBlankLine(writer);
    try Layout.writeBlankLine(writer);
}

pub fn renderFull(writer: *std.Io.Writer, use_color: bool) !void {
    const theme = Theme.init(use_color);

    try theme.write(writer, .title, "zpayload-dumper");
    try writer.writeByte('\n');
    try writer.writeAll("Android payload.bin extractor\n");
    try Layout.writeBlankLine(writer);

    try theme.write(writer, .section, "Usage");
    try writer.writeByte('\n');
    try Layout.writeSectionIndent(writer);
    try theme.write(writer, .command, "zpayload-dumper");
    try writer.writeAll(" [options] ");
    try theme.write(writer, .placeholder, "<payload.bin|ota.zip>");
    try Layout.writeBlankLine(writer);
    try Layout.writeBlankLine(writer);

    try theme.write(writer, .section, "Options");
    try writer.writeByte('\n');
    try writeOptionLine(writer, theme, Layout.section_indent, "-h, --help", "", "Show this help", null, null);
    try writeOptionLine(writer, theme, Layout.section_indent, "-v, --version", "", "Show version", null, null);
    try writeOptionLine(writer, theme, Layout.section_indent, "-l, --list", "", "Show partition list only", null, null);
    try writeOptionLine(writer, theme, Layout.section_indent, "--dry-run", "", "Simulate extraction progress without writing output", null, null);
    try writeOptionLine(writer, theme, Layout.section_indent, "-p, --partitions", " <csv>", "Extract selected partitions", null, null);
    try writeOptionLine(writer, theme, Layout.section_indent, "-o, --output", " <dir>", "Output directory", null, null);
    try writeOptionLine(writer, theme, Layout.section_indent, "--old", " <dir>", "Source partition images for delta payload extraction", null, null);
    try writeOptionLine(writer, theme, Layout.section_indent, "-c, --concurrency", " <n>", "Number of parallel partition workers", " (default: ", "nproc/2");
    try writeAliasLine(writer, theme, Layout.continuation_indent, "--color", "", "Alias for ", "--color=always");
    try writeColorModeLine(writer, theme);
    try writeAliasLine(writer, theme, Layout.continuation_indent, "--no-color", "", "Alias for ", "--color=never");
    try writeOptionLine(writer, theme, Layout.section_indent, "--format", " <mode>", "Output format", " (", "text, json");
    try writeOptionLine(writer, theme, Layout.continuation_indent, "--format=json", "", "JSON output for machine parsing", null, null);
    try Layout.writeBlankLine(writer);

    try theme.write(writer, .section, "Environment");
    try writer.writeByte('\n');
    try writeEnvLine(writer, theme, "ZPAYLOAD_COLOR=auto|always|never", "Project-specific color override");
    try writeEnvLine(writer, theme, "NO_COLOR", "Disable ANSI colors unless a command-line color flag overrides it");
    try writeEnvLine(writer, theme, "CLICOLOR=0", "Disable ANSI colors unless a command-line color flag overrides it");
    try writeEnvLine(writer, theme, "CLICOLOR_FORCE=1", "Force ANSI colors even when output is not a TTY");
    try writeEnvLine(writer, theme, "TMPDIR", "Temporary extraction base for zip input");
    try Layout.writeBlankLine(writer);

    try theme.write(writer, .section, "Examples");
    try writer.writeByte('\n');
    try writeExampleLine(writer, theme, "zpayload-dumper -l /path/to/payload.bin");
    try writeExampleLine(writer, theme, "zpayload-dumper --dry-run -p boot,vendor /path/to/payload.bin");
    try writeExampleLine(writer, theme, "zpayload-dumper -p boot,vendor -o out /path/to/payload.bin");
    try writeExampleLine(writer, theme, "zpayload-dumper --old old_images/ --output new_images/ /path/to/incremental.bin");
    try writeExampleLine(writer, theme, "zpayload-dumper --color=always /path/to/ota.zip");
    try writeExampleLine(writer, theme, "ZPAYLOAD_COLOR=never zpayload-dumper /path/to/payload.bin");
    try Layout.writeBlankLine(writer);

    try theme.write(writer, .section, "Supported Operations");
    try writer.writeByte('\n');
    try Layout.writeSectionIndent(writer);
    try writer.writeAll("Supports raw copy blocks, ");
    try theme.write(writer, .algorithm, "XZ");
    try writer.writeByte('/');
    try theme.write(writer, .algorithm, "BZip2");
    try writer.writeByte('/');
    try theme.write(writer, .algorithm, "Zstd");
    try writer.writeAll("-compressed blocks, and zero-fill operations.");
    try writer.writeByte('\n');
    try Layout.writeBlankLine(writer);

    try theme.write(writer, .section, "Notes");
    try writer.writeByte('\n');
    try Layout.writeSectionIndent(writer);
    try writer.writeAll("If ");
    try theme.write(writer, .literal, "-o");
    try writer.writeAll(" is omitted, the default output directory is ");
    try theme.write(writer, .context_value, "extracted_YYYYMMDD_HHMMSS");
    try writer.writeByte('\n');
    try Layout.writeSectionIndent(writer);
    try writer.writeAll("zip input is supported when ");
    try theme.write(writer, .literal, "payload.bin");
    try writer.writeAll(" exists inside the archive\n");
    try Layout.writeBlankLine(writer);

    try theme.write(writer, .section, "Exit Codes");
    try writer.writeByte('\n');
    try Layout.writeSectionIndent(writer);
    try writer.writeAll("0  Success\n");
    try Layout.writeSectionIndent(writer);
    try writer.writeAll("1  Runtime error (I/O, payload decode, disk space, etc.)\n");
    try Layout.writeSectionIndent(writer);
    try writer.writeAll("2  Usage error (invalid arguments, missing input)\n");
}

fn writeOptionLine(
    writer: *std.Io.Writer,
    theme: Theme,
    indent: usize,
    literal: []const u8,
    placeholder: []const u8,
    description: []const u8,
    context_prefix: ?[]const u8,
    context_value: ?[]const u8,
) !void {
    try writeSpaces(writer, indent);
    try theme.write(writer, .literal, literal);
    if (placeholder.len != 0) {
        try theme.write(writer, .placeholder, placeholder);
    }
    const pad_len = Layout.optionPadLen(indent + literal.len + placeholder.len);
    try writeSpaces(writer, pad_len);
    try writer.writeAll(description);
    if (context_prefix) |value| {
        try theme.write(writer, .context, value);
    }
    if (context_value) |value| {
        try theme.write(writer, .context_value, value);
    }
    if (context_prefix != null) {
        try theme.write(writer, .context, ")");
    }
    try writer.writeByte('\n');
}

fn writeAliasLine(
    writer: *std.Io.Writer,
    theme: Theme,
    indent: usize,
    literal: []const u8,
    placeholder: []const u8,
    description: []const u8,
    alias_literal: []const u8,
) !void {
    try writeSpaces(writer, indent);
    try theme.write(writer, .literal, literal);
    if (placeholder.len != 0) {
        try theme.write(writer, .placeholder, placeholder);
    }
    const pad_len = Layout.optionPadLen(indent + literal.len + placeholder.len);
    try writeSpaces(writer, pad_len);
    try writer.writeAll(description);
    try theme.write(writer, .literal, alias_literal);
    try writer.writeByte('\n');
}

fn writeColorModeLine(writer: *std.Io.Writer, theme: Theme) !void {
    try Layout.writeSectionIndent(writer);
    try theme.write(writer, .literal, "--color=");
    try theme.write(writer, .placeholder, "<mode>");
    const pad_len = Layout.optionPadLen(Layout.section_indent + "--color=".len + "<mode>".len);
    try writeSpaces(writer, pad_len);
    try writer.writeAll("Color mode: ");
    try theme.write(writer, .context_value, "auto, always, never");
    try writer.writeByte('\n');
}

fn writeEnvLine(writer: *std.Io.Writer, theme: Theme, name: []const u8, description: []const u8) !void {
    try Layout.writeSectionIndent(writer);
    try theme.write(writer, .literal, name);
    try writer.writeByte('\n');
    try Layout.writeContinuationIndent(writer);
    try theme.write(writer, .context, description);
    try writer.writeByte('\n');
}

fn writeExampleLine(writer: *std.Io.Writer, theme: Theme, line: []const u8) !void {
    try writeSpaces(writer, Layout.example_indent);

    var parts = std.mem.tokenizeScalar(u8, line, ' ');
    var first = true;
    while (parts.next()) |part| {
        if (!first) try writer.writeByte(' ');
        first = false;
        if (std.mem.eql(u8, part, "zpayload-dumper")) {
            try theme.write(writer, .command, part);
        } else if (std.mem.startsWith(u8, part, "ZPAYLOAD_COLOR=")) {
            if (std.mem.indexOfScalar(u8, part, '=')) |eq_index| {
                try theme.write(writer, .literal, part[0 .. eq_index + 1]);
                try theme.write(writer, .context_value, part[eq_index + 1 ..]);
            } else {
                try theme.write(writer, .literal, part);
            }
        } else if (std.mem.startsWith(u8, part, "--") or std.mem.startsWith(u8, part, "-")) {
            try theme.write(writer, .literal, part);
        } else if (std.mem.startsWith(u8, part, "/") or std.mem.endsWith(u8, part, ".bin") or std.mem.endsWith(u8, part, ".zip")) {
            try theme.write(writer, .placeholder, part);
        } else if (std.mem.indexOfScalar(u8, part, '=') != null) {
            try theme.write(writer, .literal, part);
        } else {
            try writer.writeAll(part);
        }
    }
    try writer.writeByte('\n');
}

fn writeSpaces(writer: *std.Io.Writer, count: usize) !void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) {
        try writer.writeByte(' ');
    }
}
