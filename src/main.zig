const std = @import("std");
const errors = @import("errors.zig");
const payload = @import("payload.zig");
const ui_mod = @import("cli_ui.zig");
const zip_payload = @import("input/zip_payload.zig");
const cli_args = @import("app/cli_args.zig");
const messages = @import("app/messages.zig");
const output_dir = @import("app/output_dir.zig");

const Error = errors.AppError;
const default_tmp_base = "/tmp";
const zip_suffix = ".zip";
const zip_detected_msg = "zip input detected, extracting payload.bin first";

pub fn main(init: std.process.Init) !void {
    run(init) catch |err| switch (err) {
        error.Usage, error.HelpDisplayed => return,
        else => {
            const io = init.io;
            var stderr_file = std.Io.File.stderr();
            var stderr = stderr_file.writer(io, &.{});
            stderr.interface.print("error: {s}\n", .{messages.userMessage(err)}) catch {};
            return err;
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
    const err_writer = &stderr.interface;
    const out_writer = &stdout.interface;

    const argv = init.minimal.args.toSlice(arena) catch return error.IoFailure;

    var opts = try cli_args.parseArgs(gpa, argv, out_writer, err_writer);
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
    const tmp_base = init.environ_map.get("TMPDIR") orelse default_tmp_base;
    if (std.mem.endsWith(u8, effective_payload, zip_suffix)) {
        ui.warn(zip_detected_msg, .{}) catch return error.IoFailure;
        const extracted = try zip_payload.extractPayloadBinFromZip(gpa, io, tmp_base, effective_payload);
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

    const out_path = if (opts.output) |dir| dir else blk: {
        const dir = try output_dir.makeDefaultOutputDirectory(gpa, io);
        owned_output = dir;
        break :blk dir;
    };
    std.Io.Dir.cwd().createDirPath(io, out_path) catch return error.IoFailure;
    ui.info("output dir: {s}", .{out_path}) catch return error.IoFailure;
    ui.info("workers: {d}", .{opts.concurrency}) catch return error.IoFailure;

    if (opts.partitions) |parts_csv| {
        var list = std.array_list.Managed([]const u8).init(gpa);
        defer list.deinit();

        var it = std.mem.splitScalar(u8, parts_csv, ',');
        while (it.next()) |part| {
            if (part.len != 0) try list.append(part);
        }
        ui.info("extracting selected partitions: {s}", .{parts_csv}) catch return error.IoFailure;
        try dumper.extractSelected(out_path, list.items, @intCast(opts.concurrency), &ui);
    } else {
        ui.info("extracting all partitions", .{}) catch return error.IoFailure;
        try dumper.extractAll(out_path, @intCast(opts.concurrency), &ui);
    }

    ui.success("extraction complete", .{}) catch return error.IoFailure;
}
