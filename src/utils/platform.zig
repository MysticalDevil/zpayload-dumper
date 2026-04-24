const builtin = @import("builtin");
const std = @import("std");
const errors = @import("../errors.zig");

pub const Error = errors.AppError;
pub const fallback_tmp_base = ".tmp";

const StatVfs = extern struct {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: u64,
    f_flag: u64,
    f_namemax: u64,
    __f_spare: [6]c_int,
};

extern "c" fn statvfs(path: [*:0]const u8, buf: *StatVfs) c_int;

extern "kernel32" fn GetDiskFreeSpaceExA(
    lpDirectoryName: [*:0]const u8,
    lpFreeBytesAvailableToCaller: ?*u64,
    lpTotalNumberOfBytes: ?*u64,
    lpTotalNumberOfFreeBytes: ?*u64,
) callconv(.winapi) std.os.windows.BOOL;

pub fn defaultTestTempBase() []const u8 {
    return fallback_tmp_base;
}

pub fn tempDirectorySuggestion() []const u8 {
    return "create ./.tmp or ensure the current directory is writable";
}

pub fn tempEnvironmentDescription() []const u8 {
    return "Temporary extraction base for zip/tar input (current working directory)";
}

pub fn joinOwned(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    return std.fs.path.join(allocator, parts);
}

pub fn availableBytes(path: []const u8) Error!u64 {
    return switch (builtin.os.tag) {
        .windows => availableBytesWindows(path),
        else => availableBytesPosix(path),
    };
}

fn availableBytesPosix(path: []const u8) Error!u64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.IoFailure;
    var buf: StatVfs = undefined;
    if (statvfs(path_z.ptr, &buf) != 0) return error.IoFailure;
    return buf.f_bavail * buf.f_frsize;
}

fn availableBytesWindows(path: []const u8) Error!u64 {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch return error.IoFailure;
    var free_bytes: u64 = 0;
    if (!GetDiskFreeSpaceExA(path_z.ptr, &free_bytes, null, null).toBool()) return error.IoFailure;
    return free_bytes;
}
