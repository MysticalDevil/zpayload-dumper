const std = @import("std");
const errors = @import("../errors.zig");
const c = @import("compress");

pub const Error = errors.AppError;

fn offtin(buf: *const [8]u8) i64 {
    var y: i64 = @intCast(buf[7] & 0x7F);
    y = y * 256 + @as(i64, buf[6]);
    y = y * 256 + @as(i64, buf[5]);
    y = y * 256 + @as(i64, buf[4]);
    y = y * 256 + @as(i64, buf[3]);
    y = y * 256 + @as(i64, buf[2]);
    y = y * 256 + @as(i64, buf[1]);
    y = y * 256 + @as(i64, buf[0]);
    if (buf[7] & 0x80 != 0) y = -y;
    return y;
}

/// Decompress a bzip2-compressed block into a newly-allocated buffer.
fn decompressBz2Block(allocator: std.mem.Allocator, input: []const u8) Error![]u8 {
    var stream: c.bz_stream = std.mem.zeroes(c.bz_stream);
    if (c.BZ2_bzDecompressInit(&stream, 0, 0) != c.BZ_OK) return error.Bzip2DecompressFailed;
    defer _ = c.BZ2_bzDecompressEnd(&stream);

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    stream.next_in = @ptrCast(@constCast(input.ptr));
    stream.avail_in = @intCast(input.len);

    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        stream.next_out = @ptrCast(&buf);
        stream.avail_out = buf.len;

        const rc = c.BZ2_bzDecompress(&stream);
        const produced = buf.len - @as(usize, @intCast(stream.avail_out));
        if (produced > 0) {
            result.appendSlice(buf[0..produced]) catch return error.OutOfMemory;
        }

        if (rc == c.BZ_STREAM_END) break;
        if (rc != c.BZ_OK) return error.Bzip2DecompressFailed;
    }

    return result.toOwnedSlice();
}

/// Apply a bsdiff40 patch in memory.
/// `old` is the source data, `patch` is the patch data.
/// Returns an allocator-owned buffer containing the patched output.
pub fn applyPatch(
    allocator: std.mem.Allocator,
    old: []const u8,
    patch: []const u8,
    expected_newsize: usize,
) Error![]u8 {
    if (patch.len < 32) return error.Bzip2DecompressFailed;

    const magic = "BSDIFF40";
    if (!std.mem.eql(u8, patch[0..8], magic)) return error.Bzip2DecompressFailed;

    const ctrl_len = offtin(patch[8..16]);
    const diff_len = offtin(patch[16..24]);
    const newsize_i64 = offtin(patch[24..32]);

    if (ctrl_len < 0 or diff_len < 0 or newsize_i64 < 0) return error.Bzip2DecompressFailed;
    const newsize: usize = @intCast(newsize_i64);
    if (newsize != expected_newsize) return error.Bzip2DecompressFailed;

    const header_size: usize = 32;
    const ctrl_size: usize = @intCast(ctrl_len);
    const diff_size: usize = @intCast(diff_len);

    if (ctrl_size > patch.len - header_size) return error.Bzip2DecompressFailed;
    if (diff_size > patch.len - header_size - ctrl_size) return error.Bzip2DecompressFailed;

    const ctrl_block = patch[header_size .. header_size + ctrl_size];
    const diff_block = patch[header_size + ctrl_size .. header_size + ctrl_size + diff_size];
    const extra_block = patch[header_size + ctrl_size + diff_size ..];

    // Decompress control, diff, and extra blocks.
    const ctrl = decompressBz2Block(allocator, ctrl_block) catch return error.Bzip2DecompressFailed;
    defer allocator.free(ctrl);
    const diff = decompressBz2Block(allocator, diff_block) catch return error.Bzip2DecompressFailed;
    defer allocator.free(diff);
    const extra = decompressBz2Block(allocator, extra_block) catch return error.Bzip2DecompressFailed;
    defer allocator.free(extra);

    const out = allocator.alloc(u8, newsize) catch return error.OutOfMemory;
    errdefer allocator.free(out);

    var oldpos: usize = 0;
    var newpos: usize = 0;
    var diff_pos: usize = 0;
    var extra_pos: usize = 0;
    var ctrl_pos: usize = 0;

    while (newpos < newsize) {
        if (ctrl_pos + 24 > ctrl.len) {
            allocator.free(out);
            return error.Bzip2DecompressFailed;
        }
        const add = offtin(ctrl[ctrl_pos..][0..8]);
        const copy = offtin(ctrl[ctrl_pos..][8..16]);
        const seek = offtin(ctrl[ctrl_pos..][16..24]);
        ctrl_pos += 24;

        if (add < 0 or copy < 0) {
            allocator.free(out);
            return error.Bzip2DecompressFailed;
        }

        // Diff bytes: old[i] + diff[i]
        for (0..@as(usize, @intCast(add))) |_| {
            if (newpos >= newsize) break;
            const old_val: i64 = if (oldpos < old.len) @as(i64, @as(i8, @bitCast(old[oldpos]))) else 0;
            const diff_val: i64 = if (diff_pos < diff.len) @as(i64, @as(i8, @bitCast(diff[diff_pos]))) else 0;
            out[newpos] = @bitCast(@as(i8, @intCast(old_val + diff_val)));
            newpos += 1;
            oldpos += 1;
            diff_pos += 1;
        }

        // Extra bytes: absolute data
        for (0..@as(usize, @intCast(copy))) |_| {
            if (newpos >= newsize) break;
            if (extra_pos < extra.len) {
                out[newpos] = extra[extra_pos];
            } else {
                out[newpos] = 0;
            }
            newpos += 1;
            extra_pos += 1;
        }

        if (seek < 0) {
            const backward: usize = @intCast(-seek);
            if (backward > oldpos) {
                allocator.free(out);
                return error.Bzip2DecompressFailed;
            }
            oldpos -= backward;
        } else {
            oldpos += @as(usize, @intCast(seek));
        }
    }

    return out;
}
