const std = @import("std");
const payload = @import("payload.zig");

const CliOptions = struct {
    list: bool = false,
    partitions: ?[]const u8 = null,
    output: ?[]const u8 = null,
    concurrency: i32 = 4,
    input: ?[]const u8 = null,
};

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var stderr = std.fs.File.stderr().writer(&.{});
    var stdout = std.fs.File.stdout().writer(&.{});
    const err_writer = &stderr.interface;
    const out_writer = &stdout.interface;

    const opts = parseArgs(gpa, out_writer, err_writer) catch |err| switch (err) {
        error.Usage => return,
        else => return err,
    };

    if (opts.concurrency < 1) {
        try err_writer.print("invalid concurrency {d}: must be >= 1\n", .{opts.concurrency});
        return error.InvalidConcurrency;
    }

    const input_path = opts.input.?;

    var cleanup_tmp_dir: ?[]u8 = null;
    defer if (cleanup_tmp_dir) |path| std.fs.deleteTreeAbsolute(path) catch {};

    var effective_payload = input_path;
    if (std.mem.endsWith(u8, input_path, ".zip")) {
        try out_writer.writeAll("Please wait while extracting payload.bin from the archive.\n");
        const extracted = try extractPayloadBinFromZip(gpa, input_path);
        cleanup_tmp_dir = extracted.temp_dir;
        effective_payload = extracted.payload_path;
    }

    try out_writer.print("payload.bin: {s}\n", .{effective_payload});

    var dumper = try payload.Payload.open(gpa, effective_payload);
    defer dumper.deinit();
    try dumper.init();
    try dumper.printPartitionList(out_writer);

    if (opts.list) {
        return;
    }

    const output_dir = if (opts.output) |dir| dir else try makeDefaultOutputDirectory(gpa);
    try std.fs.cwd().makePath(output_dir);

    if (opts.concurrency > 0) {
        try out_writer.print("Number of workers: {d}\n", .{opts.concurrency});
    }

    if (opts.partitions) |parts_csv| {
        var list = std.array_list.Managed([]const u8).init(gpa);
        defer list.deinit();

        var it = std.mem.splitScalar(u8, parts_csv, ',');
        while (it.next()) |part| {
            if (part.len != 0) try list.append(part);
        }
        try dumper.extractSelected(output_dir, list.items);
    } else {
        try dumper.extractAll(output_dir);
    }
}

fn parseArgs(
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    err_out: *std.Io.Writer,
) !CliOptions {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var opts = CliOptions{};
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (arg.len > 0 and arg[0] == '-') {
            if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "--list")) {
                opts.list = true;
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--partitions=")) {
                opts.partitions = arg["--partitions=".len..];
                continue;
            }
            if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--partitions")) {
                i += 1;
                if (i >= args.len) return usage(out, err_out);
                opts.partitions = args[i];
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--output=")) {
                opts.output = arg["--output=".len..];
                continue;
            }
            if (std.mem.eql(u8, arg, "-o") or std.mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= args.len) return usage(out, err_out);
                opts.output = args[i];
                continue;
            }

            if (std.mem.startsWith(u8, arg, "--concurrency=")) {
                opts.concurrency = try std.fmt.parseInt(i32, arg["--concurrency=".len..], 10);
                continue;
            }
            if (std.mem.eql(u8, arg, "-c") or std.mem.eql(u8, arg, "--concurrency")) {
                i += 1;
                if (i >= args.len) return usage(out, err_out);
                opts.concurrency = try std.fmt.parseInt(i32, args[i], 10);
                continue;
            }

            return usage(out, err_out);
        }

        if (opts.input == null) {
            opts.input = arg;
        } else {
            return usage(out, err_out);
        }
    }

    if (opts.input == null) return usage(out, err_out);
    return opts;
}

fn usage(out: *std.Io.Writer, err_out: *std.Io.Writer) error{Usage} {
    _ = out;
    err_out.writeAll(
        \\Usage: zpayload-dumper [options] [inputfile]
        \\  -l, --list                 Show list of partitions
        \\  -p, --partitions <csv>     Dump only selected partitions
        \\  -o, --output <dir>         Set output directory
        \\  -c, --concurrency <n>      Keep compatibility, must be >= 1
        \\
    ) catch {};
    return error.Usage;
}

const ZipExtractResult = struct {
    temp_dir: []u8,
    payload_path: []u8,
};

fn extractPayloadBinFromZip(allocator: std.mem.Allocator, zip_path: []const u8) !ZipExtractResult {
    const dir_path = try std.fmt.allocPrint(allocator, "/tmp/zpayload_{d}", .{std.time.nanoTimestamp()});
    try std.fs.makeDirAbsolute(dir_path);

    var zip_file = try std.fs.cwd().openFile(zip_path, .{});
    defer zip_file.close();

    var reader_buf: [4096]u8 = undefined;
    var fr = zip_file.reader(&reader_buf);
    var iter = try std.zip.Iterator.init(&fr);
    var filename_buf: [std.fs.max_path_bytes]u8 = undefined;

    var temp_dir = try std.fs.openDirAbsolute(dir_path, .{});
    defer temp_dir.close();

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

    return error.PayloadNotFoundInZip;
}

fn makeDefaultOutputDirectory(allocator: std.mem.Allocator) ![]u8 {
    var buf: [32]u8 = undefined;
    const now = std.time.timestamp();
    const dir = try std.fmt.bufPrint(&buf, "extracted_{d}", .{now});
    return try allocator.dupe(u8, dir);
}
