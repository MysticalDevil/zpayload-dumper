const std = @import("std");

const BuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
};

fn createRootModule(
    b: *std.Build,
    options: BuildOptions,
    root_source_file: []const u8,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root_source_file),
        .target = options.target,
        .optimize = options.optimize,
        .link_libc = true,
    });
}

fn createNamedExecutable(
    b: *std.Build,
    name: []const u8,
    root_module: *std.Build.Module,
) *std.Build.Step.Compile {
    return b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
}

fn addRunStep(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    compile: *std.Build.Step.Compile,
) void {
    const run = b.addRunArtifact(compile);
    if (b.args) |args| run.addArgs(args);

    const step = b.step(step_name, description);
    step.dependOn(&run.step);
}

fn createTestRun(
    b: *std.Build,
    root_module: *std.Build.Module,
) *std.Build.Step.Run {
    const tests = b.addTest(.{
        .root_module = root_module,
    });
    return b.addRunArtifact(tests);
}

fn attachPayloadDeps(
    b: *std.Build,
    module: *std.Build.Module,
    upb_out: std.Build.LazyPath,
    minitable_out: std.Build.LazyPath,
) void {
    module.addIncludePath(upb_out);
    module.addIncludePath(minitable_out);
    module.addIncludePath(b.path("src/c"));
    module.addIncludePath(b.path("third_party/utf8_range"));
    module.addCSourceFile(.{
        .file = upb_out.path(b, "update_metadata.upb.c"),
    });
    module.addCSourceFile(.{
        .file = minitable_out.path(b, "update_metadata.upb_minitable.c"),
    });
    module.addCSourceFile(.{
        .file = b.path("src/c/upb_wrap.c"),
    });
    module.addCSourceFile(.{
        .file = b.path("third_party/utf8_range/utf8_range.c"),
    });

    module.linkSystemLibrary("upb", .{});
    module.linkSystemLibrary("utf8_range", .{});
    module.linkSystemLibrary("bz2", .{});
}

fn attachIntegrationImport(module: *std.Build.Module, zpayload_mod: *std.Build.Module) void {
    module.addImport("zpayload", zpayload_mod);
}

pub fn build(b: *std.Build) void {
    const options: BuildOptions = .{
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    };

    const protoc = b.addSystemCommand(&.{"protoc"});
    const upb_out = protoc.addPrefixedOutputDirectoryArg("--upb_out=", "proto_upb");
    const minitable_out = protoc.addPrefixedOutputDirectoryArg("--upb_minitable_out=", "proto_minitable");
    protoc.addArg("--proto_path=proto");
    protoc.addArg("update_metadata.proto");

    const translate_upb = b.addTranslateC(.{
        .root_source_file = b.path("src/c/upb_wrap.h"),
        .target = options.target,
        .optimize = options.optimize,
    });
    const translate_compress = b.addTranslateC(.{
        .root_source_file = b.path("src/c/compress_headers.h"),
        .target = options.target,
        .optimize = options.optimize,
    });

    const root_module = createRootModule(b, options, "src/main.zig");
    attachPayloadDeps(b, root_module, upb_out, minitable_out);

    const zpayload_mod = createRootModule(b, options, "src/root.zig");
    attachPayloadDeps(b, zpayload_mod, upb_out, minitable_out);

    root_module.addImport("upb", translate_upb.createModule());
    root_module.addImport("compress", translate_compress.createModule());
    zpayload_mod.addImport("upb", translate_upb.createModule());
    zpayload_mod.addImport("compress", translate_compress.createModule());

    const exe = createNamedExecutable(b, "zpayload-dumper", root_module);
    b.installArtifact(exe);
    addRunStep(b, "run", "Run zpayload-dumper", exe);

    const run_tests = createTestRun(b, root_module);
    const integration_module = createRootModule(b, options, "tests/integration.zig");
    attachIntegrationImport(integration_module, zpayload_mod);
    const run_integration = createTestRun(b, integration_module);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_integration.step);

    const check_step = b.step("check", "Run the default quality gate");
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&run_integration.step);

    const stress_module = createRootModule(b, options, "tests/stress_test.zig");
    attachIntegrationImport(stress_module, zpayload_mod);
    const run_stress = createTestRun(b, stress_module);
    const stress_step = b.step("test_stress", "Run stress/integration tests");
    stress_step.dependOn(&run_stress.step);

    const e2e_module = createRootModule(b, options, "tests/e2e_test.zig");
    attachIntegrationImport(e2e_module, zpayload_mod);
    const e2e_exe = createNamedExecutable(b, "zpayload_e2e_test", e2e_module);
    addRunStep(b, "check_e2e", "Extract full payload and compare hashes with generated baseline", e2e_exe);

    const bench_module = createRootModule(b, options, "tests/smoke_benchmark.zig");
    attachIntegrationImport(bench_module, zpayload_mod);
    const bench_exe = createNamedExecutable(b, "zpayload_smoke_benchmark", bench_module);
    addRunStep(b, "bench_smoke", "Run lightweight extraction benchmark", bench_exe);

    const pressure_bench_module = createRootModule(b, options, "tests/pressure_benchmark.zig");
    attachIntegrationImport(pressure_bench_module, zpayload_mod);
    const pressure_bench_exe = createNamedExecutable(b, "zpayload_pressure_benchmark", pressure_bench_module);
    addRunStep(b, "bench_pressure", "Run pressure benchmark matrix", pressure_bench_exe);
}
