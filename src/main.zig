const std = @import("std");
const payload = @import("payload.zig");
const ui_mod = @import("cli_ui.zig");

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

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    var stderr_file = std.Io.File.stderr();
    var stdout_file = std.Io.File.stdout();
    var stderr = stderr_file.writer(io, &.{});
    var stdout = stdout_file.writer(io, &.{});
    const err_writer = &stderr.interface;
    const out_writer = &stdout.interface;

    const argv = try init.minimal.args.toSlice(arena);

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
        try ui.fail("invalid concurrency {d}: must be >= 1", .{opts.concurrency});
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
        try ui.warn("zip input detected, extracting payload.bin first", .{});
        const extracted = try extractPayloadBinFromZip(gpa, io, tmp_base, effective_payload);
        cleanup_tmp_dir = extracted.temp_dir;
        cleanup_payload_path = extracted.payload_path;
        effective_payload = extracted.payload_path;
    }

    try ui.info("input: {s}", .{effective_payload});

    var dumper = try payload.Payload.open(gpa, io, effective_payload);
    defer dumper.deinit();
    try dumper.init();

    const partition_count = try dumper.partitionCount();
    try ui.info("manifest parsed, partitions: {d}", .{partition_count});
    try dumper.printPartitionList(out_writer);

    if (opts.list) {
        try ui.success("list mode complete", .{});
        return;
    }

    var owned_output: ?[]u8 = null;
    defer if (owned_output) |dir| gpa.free(dir);

    const output_dir = if (opts.output) |dir| dir else blk: {
        const dir = try makeDefaultOutputDirectory(gpa, io);
        owned_output = dir;
        break :blk dir;
    };
    try std.Io.Dir.cwd().createDirPath(io, output_dir);
    try ui.info("output dir: {s}", .{output_dir});
    try ui.info("workers: {d}", .{opts.concurrency});

    if (opts.partitions) |parts_csv| {
        var list = std.array_list.Managed([]const u8).init(gpa);
        defer list.deinit();

        var it = std.mem.splitScalar(u8, parts_csv, ',');
        while (it.next()) |part| {
            if (part.len != 0) try list.append(part);
        }
        try ui.info("extracting selected partitions: {s}", .{parts_csv});
        try dumper.extractSelected(output_dir, list.items, @intCast(opts.concurrency), &ui);
    } else {
        try ui.info("extracting all partitions", .{});
        try dumper.extractAll(output_dir, @intCast(opts.concurrency), &ui);
    }

    try ui.success("extraction complete", .{});
}

fn parseArgs(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !CliOptions {
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
                opts.concurrency = try std.fmt.parseInt(i32, arg["--concurrency=".len..], 10);
                continue;
            }
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
                i += 1;
                if (i >= args.len) return usage(err_out);
                opts.concurrency = try std.fmt.parseInt(i32, args[i], 10);
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

fn replaceOwned(allocator: std.mem.Allocator, slot: *?[]u8, value: []const u8) !void {
    if (slot.*) |old| allocator.free(old);
    slot.* = try allocator.dupe(u8, value);
}

fn usage(err_out: *std.Io.Writer) error{Usage} {
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
    try out.writeAll(
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
    );
}

const ZipExtractResult = struct {
    temp_dir: []u8,
    payload_path: []u8,
};

fn extractPayloadBinFromZip(allocator: std.mem.Allocator, io: std.Io, tmp_base: []const u8, zip_path: []const u8) !ZipExtractResult {
    var nonce: u64 = undefined;
    io.random(std.mem.asBytes(&nonce));
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/zpayload_{d}", .{ tmp_base, nonce });
    try std.Io.Dir.createDirAbsolute(io, dir_path, .default_dir);

    var zip_file = try std.Io.Dir.cwd().openFile(io, zip_path, .{});
    defer zip_file.close(io);

    var reader_buf: [4096]u8 = undefined;
    var fr = zip_file.reader(io, &reader_buf);
    var iter = try std.zip.Iterator.init(&fr);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    var temp_dir = try std.Io.Dir.openDirAbsolute(io, dir_path, .{});
    defer temp_dir.close(io);

    while (try iter.next()) |entry| {
        try fr.seekTo(entry.header_zip_offset + @sizeOf(std.zip.CentralDirectoryFileHeader));
        const name = filename_buf[0..entry.filename_len];
        try fr.interface.readSliceAll(name);
        if (std.mem.eql(u8, name, "payload.bin")) {
            try entry.extract(&fr, .{}, &filename_buf, temp_dir);
            const payload_path = try std.fmt.allocPrint(allocator, "{s}/payload.bin", .{dir_path});
            return .{ .temp_dir = dir_path, .payload_path = payload_path };
        }
    }

    allocator.free(dir_path);
    return error.PayloadNotFoundInZip;
}

fn makeDefaultOutputDirectory(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const now = std.Io.Timestamp.now(io, .real).toSeconds();
    if (now < 0) return error.InvalidSystemTime;

    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(now) };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_secs = epoch_seconds.getDaySeconds();

    const year: u16 = year_day.year;
    const month: u4 = month_day.month.numeric();
    const day: u5 = month_day.day_index + 1;
    const hour: u5 = day_secs.getHoursIntoDay();
    const minute: u6 = day_secs.getMinutesIntoHour();
    const second: u6 = day_secs.getSecondsIntoMinute();

    var buf: [64]u8 = undefined;
    const dir = try std.fmt.bufPrint(&buf, "extracted_{d:0>4}{d:0>2}{d:0>2}_{d:0>2}{d:0>2}{d:0>2}", .{
        year, month, day, hour, minute, second,
    });
    return try allocator.dupe(u8, dir);
}
