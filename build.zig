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
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_module,
    });
    exe.link_gc_sections = false;
    return exe;
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
    protobuf_mod: *std.Build.Module,
) void {
    module.addImport("protobuf", protobuf_mod);
    module.addIncludePath(b.path("src/c"));
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

    const version_opt = b.option([]const u8, "version", "Override version string (default: from build.zig.zon)");
    const version_string = blk: {
        if (version_opt) |v| break :blk v;
        const zon = @import("build.zig.zon");
        break :blk b.allocator.dupe(u8, zon.version) catch "dev-unknown";
    };
    const cache_root_path = b.cache_root.path orelse @panic("std.Build cache_root.path is unavailable");
    const local_cache_dir = b.allocator.dupe(u8, cache_root_path) catch @panic("OOM");

    const bsdiff_enabled = b.option(bool, "bsdiff", "Enable SOURCE_BSDIFF support") orelse false;

    const build_options = b.addOptions();
    build_options.addOption([]const u8, "version", version_string);
    build_options.addOption([]const u8, "local_cache_dir", local_cache_dir);
    build_options.addOption(bool, "bsdiff_enabled", bsdiff_enabled);

    // --- zig-protobuf dependency ---
    const protobuf_dep = b.dependency("protobuf", .{
        .target = options.target,
        .optimize = options.optimize,
    });
    const protobuf_mod = protobuf_dep.module("protobuf");

    // --- Translate-C for bzip2 (compress_headers.h) ---
    const translate_compress = b.addTranslateC(.{
        .root_source_file = b.path("src/c/compress_headers.h"),
        .target = options.target,
        .optimize = options.optimize,
    });

    // --- Core modules ---
    const root_module = createRootModule(b, options, "src/main.zig");
    root_module.addOptions("build_options", build_options);
    attachPayloadDeps(b, root_module, protobuf_mod);

    const zpayload_mod = createRootModule(b, options, "src/root.zig");
    attachPayloadDeps(b, zpayload_mod, protobuf_mod);

    root_module.addImport("compress", translate_compress.createModule());
    zpayload_mod.addImport("compress", translate_compress.createModule());

    // --- Executable ---
    const exe = createNamedExecutable(b, "zpayload-dumper", root_module);
    b.installArtifact(exe);
    addRunStep(b, "run", "Run zpayload-dumper", exe);

    // --- Tests ---
    const run_tests = createTestRun(b, root_module);
    const integration_module = createRootModule(b, options, "tests/integration.zig");
    integration_module.addOptions("build_options", build_options);
    attachIntegrationImport(integration_module, zpayload_mod);
    const run_integration = createTestRun(b, integration_module);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_integration.step);

    const check_step = b.step("check", "Run the default quality gate");
    check_step.dependOn(&run_tests.step);
    check_step.dependOn(&run_integration.step);

    const stress_module = createRootModule(b, options, "tests/stress_test.zig");
    stress_module.addOptions("build_options", build_options);
    attachIntegrationImport(stress_module, zpayload_mod);
    const run_stress = createTestRun(b, stress_module);
    const stress_step = b.step("test_stress", "Run stress/integration tests");
    stress_step.dependOn(&run_stress.step);

    const e2e_module = createRootModule(b, options, "tests/e2e_test.zig");
    e2e_module.addOptions("build_options", build_options);
    attachIntegrationImport(e2e_module, zpayload_mod);
    const e2e_exe = createNamedExecutable(b, "zpayload_e2e_test", e2e_module);
    addRunStep(b, "check_e2e", "Extract full payload and compare hashes with generated baseline", e2e_exe);

    const bench_module = createRootModule(b, options, "tests/smoke_benchmark.zig");
    bench_module.addOptions("build_options", build_options);
    attachIntegrationImport(bench_module, zpayload_mod);
    const bench_exe = createNamedExecutable(b, "zpayload_smoke_benchmark", bench_module);
    addRunStep(b, "bench_smoke", "Run lightweight extraction benchmark", bench_exe);

    const pressure_bench_module = createRootModule(b, options, "tests/pressure_benchmark.zig");
    pressure_bench_module.addOptions("build_options", build_options);
    attachIntegrationImport(pressure_bench_module, zpayload_mod);
    const pressure_bench_exe = createNamedExecutable(b, "zpayload_pressure_benchmark", pressure_bench_module);
    addRunStep(b, "bench_pressure", "Run pressure benchmark matrix", pressure_bench_exe);
}
