const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protoc = b.addSystemCommand(&.{ "protoc" });
    const upb_out = protoc.addPrefixedOutputDirectoryArg("--upb_out=", "proto_upb");
    const minitable_out = protoc.addPrefixedOutputDirectoryArg("--upb_minitable_out=", "proto_minitable");
    protoc.addArg("--proto_path=proto");
    protoc.addArg("update_metadata.proto");

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    root_module.addIncludePath(upb_out);
    root_module.addIncludePath(minitable_out);
    root_module.addIncludePath(b.path("src/c"));
    root_module.addCSourceFile(.{
        .file = upb_out.path(b, "update_metadata.upb.c"),
    });
    root_module.addCSourceFile(.{
        .file = minitable_out.path(b, "update_metadata.upb_minitable.c"),
    });
    root_module.addCSourceFile(.{
        .file = b.path("src/c/upb_wrap.c"),
    });

    root_module.linkSystemLibrary("upb", .{});
    root_module.linkSystemLibrary("utf8_range", .{});
    root_module.linkSystemLibrary("lzma", .{});
    root_module.linkSystemLibrary("bz2", .{});
    root_module.linkSystemLibrary("zstd", .{});

    const exe = b.addExecutable(.{
        .name = "zpayload-dumper",
        .root_module = root_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zpayload-dumper");
    run_step.dependOn(&run_cmd.step);

    const unit_tests = b.addTest(.{
        .root_module = root_module,
    });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
