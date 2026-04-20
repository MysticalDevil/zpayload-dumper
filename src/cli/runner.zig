const std = @import("std");
const errors = @import("../errors.zig");
const payload = @import("../payload/root.zig");
const zip_payload = @import("../input/payload_zip.zig");
const render = @import("render.zig");
const types = @import("types.zig");
const cli_ui = @import("ui.zig");
const output = @import("output.zig");

const Error = errors.AppError;
const default_tmp_base = "/tmp";
const zip_suffix = ".zip";

pub fn run(
    init: std.process.Init,
    options: *const types.CliOptions,
    ui: *const cli_ui.Ui,
    reporter: *const payload.Reporter,
) Error!void {
    const gpa = init.gpa;
    const io = init.io;

    if (options.concurrency < 1) {
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

    var effective_payload = options.input;
    const tmp_base = init.environ_map.get("TMPDIR") orelse default_tmp_base;
    if (std.mem.endsWith(u8, effective_payload, zip_suffix)) {
        ui.warn("zip input detected, extracting payload.bin first") catch return error.IoFailure;
        const extracted = try zip_payload.extractPayloadBinFromZip(gpa, io, tmp_base, effective_payload);
        cleanup_tmp_dir = extracted.temp_dir;
        cleanup_payload_path = extracted.payload_path;
        effective_payload = extracted.payload_path;
    }

    try logPath(ui, "input: {s}", effective_payload);

    var dumper = try payload.Payload.open(gpa, io, effective_payload);
    defer dumper.deinit();
    try dumper.init();

    const partition_count = try dumper.partitionCount();
    {
        var partition_buffer: [128]u8 = undefined;
        const partition_message = std.fmt.bufPrint(&partition_buffer, "manifest parsed, partitions: {d}", .{partition_count}) catch return error.IoFailure;
        ui.info(partition_message) catch return error.IoFailure;
    }
    dumper.printPartitionList(reporter.out) catch return error.IoFailure;

    if (options.list) {
        ui.success("list mode complete") catch return error.IoFailure;
        return;
    }

    var owned_output: ?[]u8 = null;
    defer if (owned_output) |dir| gpa.free(dir);

    const out_path = if (options.output) |value| value else blk: {
        const generated = try output.makeDefaultOutputDirectory(gpa, io);
        owned_output = generated;
        break :blk generated;
    };
    if (options.dry_run) {
        try logPath(ui, "output dir (dry-run): {s}", out_path);
    } else {
        std.Io.Dir.cwd().createDirPath(io, out_path) catch return error.IoFailure;
        try logPath(ui, "output dir: {s}", out_path);
    }

    {
        var workers_buffer: [96]u8 = undefined;
        const workers_message = std.fmt.bufPrint(&workers_buffer, "workers: {d}", .{options.concurrency}) catch return error.IoFailure;
        ui.info(workers_message) catch return error.IoFailure;
    }

    if (options.partitions) |parts_csv| {
        var selected = std.array_list.Managed([]const u8).init(gpa);
        defer selected.deinit();
        try splitPartitions(&selected, parts_csv);

        {
            var select_buffer: [256]u8 = undefined;
            const select_message = blk: {
                if (options.dry_run) {
                    break :blk std.fmt.bufPrint(&select_buffer, "dry-run simulating selected partitions: {s}", .{parts_csv}) catch return error.IoFailure;
                }
                break :blk std.fmt.bufPrint(&select_buffer, "extracting selected partitions: {s}", .{parts_csv}) catch return error.IoFailure;
            };
            ui.info(select_message) catch return error.IoFailure;
        }
        if (options.dry_run) {
            try dumper.extractSelectedDryRun(selected.items, @intCast(options.concurrency), reporter, render.sink);
        } else {
            try dumper.extractSelected(out_path, selected.items, @intCast(options.concurrency), reporter, render.sink);
        }
    } else {
        ui.info(if (options.dry_run) "dry-run simulating all partitions" else "extracting all partitions") catch return error.IoFailure;
        if (options.dry_run) {
            try dumper.extractSelectedDryRun(&.{}, @intCast(options.concurrency), reporter, render.sink);
        } else {
            try dumper.extractSelected(out_path, &.{}, @intCast(options.concurrency), reporter, render.sink);
        }
    }

    ui.success(if (options.dry_run) "dry-run complete" else "extraction complete") catch return error.IoFailure;
}

fn splitPartitions(list: *std.array_list.Managed([]const u8), csv: []const u8) !void {
    var iterator = std.mem.splitScalar(u8, csv, ',');
    while (iterator.next()) |entry| {
        if (entry.len != 0) try list.append(entry);
    }
}

fn logPath(ui: *const cli_ui.Ui, comptime fmt: []const u8, value: []const u8) !void {
    var buffer: [256]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, fmt, .{value}) catch return error.IoFailure;
    ui.info(message) catch return error.IoFailure;
}
