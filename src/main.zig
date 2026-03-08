const std = @import("std");
const errors = @import("errors.zig");
const payload = @import("payload.zig");
const ui_mod = @import("cli_ui.zig");
const c = @cImport({
    @cInclude("time.h");
});

const Error = errors.AppError;

const CliOptions = struct {
    allocator: std.mem.Allocator,
    list: bool = false,
    partitions: ?[]u8 = null,
    output: ?[]u8 = null,
    concurrency: i32 = 4,
    input: ?[]u8 = null,
    color_mode: ui_mod.ColorMode = .auto,

    fn init(allocator: std.mem.Allocator) CliOptions {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *CliOptions) void {
        if (self.partitions) |v| self.allocator.free(v);
        if (self.output) |v| self.allocator.free(v);
        if (self.input) |v| self.allocator.free(v);
    }
};

pub fn main(init: std.process.Init) Error!void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_file = std.Io.File.stderr();
    var stdout_file = std.Io.File.stdout();
    var stderr = stderr_file.writer(io, &.{});
    var stdout = stdout_file.writer(io, &.{});
    const err_writer = &stderr.interface;
    const out_writer = &stdout.interface;

    const argv = init.minimal.args.toSlice(arena) catch return error.IoFailure;

    var opts = parseArgs(gpa, argv, out_writer, err_writer) catch |err| switch (err) {
        error.Usage, error.HelpDisplayed => return,
        else => return err,
    };
    defer opts.deinit();

    const auto_color = stdout_file.isTty(io) catch |err| blk: {
        std.log.warn("failed to detect tty for color auto mode: {}", .{err});
        break :blk false;
    };
    var ui = ui_mod.Ui.init(out_writer, err_writer, opts.color_mode, auto_color);

    if (opts.concurrency < 1) {
        ui.fail("invalid concurrency {d}: must be >= 1", .{opts.concurrency}) catch return error.IoFailure;
        return error.InvalidConcurrency;
    }

    var cleanup_tmp_dir: ?[]u8 = null;
    var cleanup_payload_path: ?[]u8 = null;
    defer if (cleanup_payload_path) |path| gpa.free(path);
    defer if (cleanup_tmp_dir) |path| {
        std.Io.Dir.cwd().deleteTree(io, path) catch |err| {
            std.log.warn("failed to cleanup temporary directory '{s}': {}", .{ path, err });
        };
        gpa.free(path);
    };

    var effective_payload = opts.input.?;
    const tmp_base = init.environ_map.get("TMPDIR") orelse "/tmp";
    if (std.mem.endsWith(u8, effective_payload, ".zip")) {
        ui.warn("zip input detected, extracting payload.bin first", .{}) catch return error.IoFailure;
        const extracted = try extractPayloadBinFromZip(gpa, io, tmp_base, effective_payload);
        cleanup_tmp_dir = extracted.temp_dir;
        cleanup_payload_path = extracted.payload_path;
        effective_payload = extracted.payload_path;
    }

    ui.info("input: {s}", .{effective_payload}) catch return error.IoFailure;

    var dumper = try payload.Payload.open(gpa, io, effective_payload);
    defer dumper.deinit();
    try dumper.init();

    const partition_count = try dumper.partitionCount();
    ui.info("manifest parsed, partitions: {d}", .{partition_count}) catch return error.IoFailure;
    try dumper.printPartitionList(out_writer);

    if (opts.list) {
        ui.success("list mode complete", .{}) catch return error.IoFailure;
        return;
    }

    var owned_output: ?[]u8 = null;
    defer if (owned_output) |dir| gpa.free(dir);

    const output_dir = if (opts.output) |dir| dir else blk: {
        const dir = try makeDefaultOutputDirectory(gpa, io);
        owned_output = dir;
        break :blk dir;
    };
    std.Io.Dir.cwd().createDirPath(io, output_dir) catch return error.IoFailure;
    ui.info("output dir: {s}", .{output_dir}) catch return error.IoFailure;
    ui.info("workers: {d}", .{opts.concurrency}) catch return error.IoFailure;

    if (opts.partitions) |parts_csv| {
        var list = std.array_list.Managed([]const u8).init(gpa);
        defer list.deinit();

        var it = std.mem.splitScalar(u8, parts_csv, ',');
        while (it.next()) |part| {
            if (part.len != 0) try list.append(part);
        }
        ui.info("extracting selected partitions: {s}", .{parts_csv}) catch return error.IoFailure;
        try dumper.extractSelected(output_dir, list.items, @intCast(opts.concurrency), &ui);
    } else {
        ui.info("extracting all partitions", .{}) catch return error.IoFailure;
        try dumper.extractAll(output_dir, @intCast(opts.concurrency), &ui);
    }

    ui.success("extraction complete", .{}) catch return error.IoFailure;
}

fn parseArgs(
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

fn help(out: *std.Io.Writer) !void {
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
        \\  zpayload-dumper -l testdata/payload.bin
        \\  zpayload-dumper -p boot,vendor -o out testdata/payload.bin
        \\  zpayload-dumper testdata/payload.zip
        \\
        \\Supported operations:
        \\  REPLACE, REPLACE_XZ, REPLACE_BZ, ZSTD, ZERO
        \\
    ) catch return error.IoFailure;
}

const ZipExtractResult = struct {
    temp_dir: []u8,
    payload_path: []u8,
};

fn extractPayloadBinFromZip(allocator: std.mem.Allocator, io: std.Io, tmp_base: []const u8, zip_path: []const u8) Error!ZipExtractResult {
    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/zpayload_{d}", .{ tmp_base, nonce });
    std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir) catch return error.IoFailure;

    var zip_file = std.Io.Dir.cwd().openFile(io, zip_path, .{}) catch return error.InvalidZipArchive;
    defer zip_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr = zip_file.reader(io, &reader_buf);
    var iter = std.zip.Iterator.init(&fr) catch return error.InvalidZipArchive;
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    var temp_dir = std.Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return error.IoFailure;
    defer temp_dir.close(io);

    while (iter.next() catch return error.InvalidZipArchive) |entry| {
        fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader)) catch return error.InvalidZipArchive;
        const name = filename_buf[0..entry.filename_len];
        fr.interface.readSliceAll(name) catch return error.InvalidZipArchive;
        if (std.mem.eql(u8, name, "payload.bin")) {
            entry.extract(&fr, .{}, &filename_buf, temp_dir) catch return error.InvalidZipArchive;
            const payload_path = try std.fmt.allocPrint(allocator, "{s}/payload.bin", .{dir_path});
            return .{ .temp_dir = dir_path, .payload_path = payload_path };
        }
    }

    allocator.free(dir_path);
    return error.PayloadNotFoundInZip;
}

fn makeDefaultOutputDirectory(allocator: std.mem.Allocator, io: std.Io) Error![]u8 {
    _ = io;
    var now = c.time(null);
    if (now < 0) return error.TimeUnavailable;
    var tm_buf: c.struct_tm = undefined;
    if (c.localtime_r(&now, &tm_buf) == null) return error.TimeUnavailable;

    const year: i32 = tm_buf.tm_year + 1900;
    const month: i32 = tm_buf.tm_mon + 1;
    const day: i32 = tm_buf.tm_mday;
    const hour: i32 = tm_buf.tm_hour;
    const minute: i32 = tm_buf.tm_min;
    const second: i32 = tm_buf.tm_sec;

    var buf: [64]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "extracted_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
        year, month, day, hour, minute, second,
    }) catch return error.IoFailure;
    return try allocator.dupe(u8, dir);
}
