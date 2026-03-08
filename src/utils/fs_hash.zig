const std = @import("std");

pub fn hashFileAtPath(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![32]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    const buf = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(buf);

    var off: u64 = 0;
    while (off < stat.size) {
        const n: usize = @intCast(@min(stat.size - off, buf.len));
        _ = try file.readPositionalAll(io, buf[0..n], off);
        hasher.update(buf[0..n]);
        off += n;
    }

    var out: [32]u8 = undefined;
    hasher.final(&out);
    return out;
}

pub fn assertFileHashEqual(allocator: std.mem.Allocator, io: std.Io, expected_path: []const u8, actual_path: []const u8) !void {
    const expected_hash = try hashFileAtPath(allocator, io, expected_path);
    const actual_hash = try hashFileAtPath(allocator, io, actual_path);
    try std.testing.expectEqualSlices(u8, &expected_hash, &actual_hash);
}

pub fn fileExists(io: std.Io, path: []const u8) bool {
    std.Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn countFilesInDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var walker = try std.Io.Dir.walk(dir, allocator);
    defer walker.deinit();

    var n: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) n += 1;
    }
    return n;
}

pub fn compareDirs(allocator: std.mem.Allocator, io: std.Io, baseline_dir: []const u8, output_dir: []const u8) !void {
    var baseline_open = try std.Io.Dir.cwd().openDir(io, baseline_dir, .{ .iterate = true });
    defer baseline_open.close(io);

    var walker = try std.Io.Dir.walk(baseline_open, allocator);
    defer walker.deinit();

    var baseline_count: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        baseline_count += 1;

        const expected_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ baseline_dir, entry.path });
        defer allocator.free(expected_path);
        const actual_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ output_dir, entry.path });
        defer allocator.free(actual_path);

        const expected_stat = try std.Io.Dir.cwd().statFile(io, expected_path, .{});
        const actual_stat = try std.Io.Dir.cwd().statFile(io, actual_path, .{});
        if (expected_stat.size != actual_stat.size) return error.SizeMismatch;

        const expected_hash = try hashFileAtPath(allocator, io, expected_path);
        const actual_hash = try hashFileAtPath(allocator, io, actual_path);
        if (!std.mem.eql(u8, &expected_hash, &actual_hash)) return error.HashMismatch;
    }

    var output_open = try std.Io.Dir.cwd().openDir(io, output_dir, .{ .iterate = true });
    defer output_open.close(io);
    var out_walker = try std.Io.Dir.walk(output_open, allocator);
    defer out_walker.deinit();

    var output_count: usize = 0;
    while (try out_walker.next(io)) |entry| {
        if (entry.kind == .file) output_count += 1;
    }
    if (baseline_count != output_count) return error.FileCountMismatch;
}
