const std = @import("std");
const errors = @import("../errors.zig");
const payload = @import("../payload/root.zig");
const input_mod = @import("../input/root.zig");
const archive_common = input_mod.archive_common;
const zip_payload = input_mod.payload_zip;
const tar_payload = input_mod.payload_tar;
const render = @import("render.zig");
const types = @import("types.zig");
const cli_ui = @import("ui.zig");
const output = @import("output.zig");

const Error = errors.AppError;
const platform = @import("../utils/platform.zig");
const zip_suffix = ".zip";
const tar_suffixes = [_][]const u8{ ".tar", ".tar.gz", ".tgz" };

pub fn run(
    init: std.process.Init,
    options: *const types.CliOptions,
    ui: *const cli_ui.Ui,
    reporter: *const payload.Reporter,
    bsdiff_enabled: bool,
) Error!void {
    const gpa = init.gpa;
    const io = init.io;

    const effective_concurrency = blk: {
        if (options.concurrency) |value| {
            if (value < 1) return error.InvalidConcurrency;
            break :blk @as(usize, @intCast(value));
        }
        const cpu_count = std.Thread.getCpuCount() catch 1;
        break :blk @max(1, cpu_count / 2);
    };

    var cleanup_archive_tmp_dir: ?[]u8 = null;
    var cleanup_payload_path: ?[]u8 = null;
    defer if (cleanup_payload_path) |path| gpa.free(path);
    defer if (cleanup_archive_tmp_dir) |path| {
        archive_common.cleanupExtractedPayloadTempDir(io, path) catch |err| {
            std.log.warn("failed to cleanup temporary directory '{s}': {}", .{ path, err });
        };
        gpa.free(path);
    };

    const is_zip_input = std.mem.endsWith(u8, options.input, zip_suffix);
    const is_tar_input = blk: {
        for (tar_suffixes) |suffix| {
            if (std.mem.endsWith(u8, options.input, suffix)) break :blk true;
        }
        break :blk false;
    };
    const is_archive_input = is_zip_input or is_tar_input;

    if (is_archive_input and options.dry_run) {
        if (is_zip_input) {
            ui.warn("zip input detected, reading payload metadata in memory for dry-run") catch return error.IoFailure;
            try logPath(ui, "input zip: {s}", options.input);
            var metadata = try zip_payload.readPayloadMetadataFromZip(gpa, io, options.input);
            defer metadata.deinit(gpa);
            var dumper = payload.Payload{
                .allocator = gpa,
                .io = io,
                .file = null,
                .header = .{},
                .metadata_size = 0,
                .data_offset = 0,
                .ctx = undefined,
                .ctx_initialized = false,
            };
            defer dumper.deinit();
            try dumper.initFromMetadata(metadata.manifest, metadata.signature);
            return runWithPayload(&dumper, options, ui, reporter, effective_concurrency, is_archive_input, bsdiff_enabled);
        } else {
            ui.warn("tar input detected, reading payload metadata in memory for dry-run") catch return error.IoFailure;
            try logPath(ui, "input tar: {s}", options.input);
            var metadata = try tar_payload.readPayloadMetadataFromTar(gpa, io, options.input);
            defer metadata.deinit(gpa);
            var dumper = payload.Payload{
                .allocator = gpa,
                .io = io,
                .file = null,
                .header = .{},
                .metadata_size = 0,
                .data_offset = 0,
                .ctx = undefined,
                .ctx_initialized = false,
            };
            defer dumper.deinit();
            try dumper.initFromMetadata(metadata.manifest, metadata.signature);
            return runWithPayload(&dumper, options, ui, reporter, effective_concurrency, is_archive_input, bsdiff_enabled);
        }
    } else {
        var effective_payload: []const u8 = options.input;
        const tmp_base = platform.resolveTempBase(init.environ_map);
        if (is_zip_input) {
            ui.warn("zip input detected, extracting payload.bin first") catch return error.IoFailure;
            const extracted = try zip_payload.extractPayloadBinFromZip(gpa, io, tmp_base, options.input);
            if (extracted.used_fallback_tmp) {
                ui.warn("temporary extraction moved to ./.tmp because the preferred temp directory does not have enough free space") catch return error.IoFailure;
            }
            cleanup_archive_tmp_dir = extracted.temp_dir;
            cleanup_payload_path = extracted.payload_path;
            effective_payload = extracted.payload_path;
        } else if (is_tar_input) {
            ui.warn("tar input detected, extracting payload.bin first") catch return error.IoFailure;
            const extracted = try tar_payload.extractPayloadBinFromTar(gpa, io, tmp_base, options.input);
            if (extracted.used_fallback_tmp) {
                ui.warn("temporary extraction moved to ./.tmp because the preferred temp directory does not have enough free space") catch return error.IoFailure;
            }
            cleanup_archive_tmp_dir = extracted.temp_dir;
            cleanup_payload_path = extracted.payload_path;
            effective_payload = extracted.payload_path;
        }

        try logPath(ui, "input: {s}", effective_payload);
        var dumper = try payload.Payload.open(gpa, io, effective_payload);
        defer dumper.deinit();
        try dumper.init();
        return runWithPayload(&dumper, options, ui, reporter, effective_concurrency, is_archive_input, bsdiff_enabled);
    }
}

fn runWithPayload(
    dumper: *payload.Payload,
    options: *const types.CliOptions,
    ui: *const cli_ui.Ui,
    reporter: *const payload.Reporter,
    effective_concurrency: usize,
    is_archive_input: bool,
    bsdiff_enabled: bool,
) Error!void {
    const gpa = dumper.allocator;
    const io = dumper.io;

    if (is_archive_input and options.dry_run) {
        try logPath(ui, "metadata source: {s}", "payload.bin inside archive (in-memory)");
    }

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
        const workers_message = std.fmt.bufPrint(&workers_buffer, "workers: {d}", .{effective_concurrency}) catch return error.IoFailure;
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
        const old_dir: ?[]const u8 = options.old_dir;
        if (options.dry_run) {
            try dumper.extractSelectedDryRun(selected.items, effective_concurrency, reporter, render.sink, old_dir, bsdiff_enabled);
        } else {
            try dumper.extractSelected(out_path, selected.items, effective_concurrency, reporter, render.sink, old_dir, bsdiff_enabled);
        }
    } else {
        const old_dir: ?[]const u8 = options.old_dir;
        ui.info(if (options.dry_run) "dry-run simulating all partitions" else "extracting all partitions") catch return error.IoFailure;
        if (options.dry_run) {
            try dumper.extractSelectedDryRun(&.{}, effective_concurrency, reporter, render.sink, old_dir, bsdiff_enabled);
        } else {
            try dumper.extractSelected(out_path, &.{}, effective_concurrency, reporter, render.sink, old_dir, bsdiff_enabled);
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
