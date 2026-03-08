const std = @import("std");

fn attachPayloadDeps(b: *std.Build, module: *std.Build.Module, upb_out: std.Build.LazyPath, minitable_out: std.Build.LazyPath) void {
    module.addIncludePath(upb_out);
    module.addIncludePath(minitable_out);
    module.addIncludePath(b.path("src/c"));
    module.addCSourceFile(.{
        .file = upb_out.path(b, "update_metadata.upb.c"),
    });
    module.addCSourceFile(.{
        .file = minitable_out.path(b, "update_metadata.upb_minitable.c"),
    });
    module.addCSourceFile(.{
        .file = b.path("src/c/upb_wrap.c"),
    });

    module.linkSystemLibrary("upb", .{});
    module.linkSystemLibrary("utf8_range", .{});
    module.linkSystemLibrary("lzma", .{});
    module.linkSystemLibrary("bz2", .{});
    module.linkSystemLibrary("zstd", .{});
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const protoc = b.addSystemCommand(&.{"protoc"});
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
    attachPayloadDeps(b, root_module, upb_out, minitable_out);

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
    const integration_module = b.createModule(.{
        .root_source_file = b.path("src/integration_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attachPayloadDeps(b, integration_module, upb_out, minitable_out);
    const integration_tests = b.addTest(.{
        .root_module = integration_module,
    });
    const run_integration = b.addRunArtifact(integration_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_integration.step);

    const stress_module = b.createModule(.{
        .root_source_file = b.path("src/stress_tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attachPayloadDeps(b, stress_module, upb_out, minitable_out);
    const stress_tests = b.addTest(.{
        .root_module = stress_module,
    });
    const run_stress = b.addRunArtifact(stress_tests);
    const stress_step = b.step("test-stress", "Run stress/integration tests");
    stress_step.dependOn(&run_stress.step);

    const e2e_module = b.createModule(.{
        .root_source_file = b.path("src/e2e_check.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    attachPayloadDeps(b, e2e_module, upb_out, minitable_out);
    const e2e_exe = b.addExecutable(.{
        .name = "zpayload-e2e-check",
        .root_module = e2e_module,
    });
    const run_e2e = b.addRunArtifact(e2e_exe);
    const e2e_step = b.step("check-e2e", "Extract full payload and compare hashes with go baseline");
    e2e_step.dependOn(&run_e2e.step);
}
