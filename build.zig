const std = @import("std");
const deps = @import("build_deps.zig");

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

fn isWindowsTarget(target: std.Build.ResolvedTarget) bool {
    return target.result.os.tag == .windows;
}

fn addSourceFiles(
    b: *std.Build,
    module: *std.Build.Module,
    base_dir: []const u8,
    sources: []const []const u8,
) void {
    for (sources) |source| {
        module.addCSourceFile(.{
            .file = b.path(b.pathJoin(&.{ base_dir, source })),
        });
    }
}

fn attachVendoredPayloadDeps(
    b: *std.Build,
    module: *std.Build.Module,
    upb_out: std.Build.LazyPath,
    minitable_out: std.Build.LazyPath,
) void {
    module.addIncludePath(upb_out);
    module.addIncludePath(minitable_out);
    module.addIncludePath(b.path("src/c"));
    module.addIncludePath(b.path("third_party/protobuf"));
    module.addIncludePath(b.path("third_party/protobuf/upb/reflection/cmake"));
    module.addIncludePath(b.path("third_party/protobuf/third_party/utf8_range"));
    module.addIncludePath(b.path("third_party/bzip2"));
    module.addCSourceFile(.{
        .file = upb_out.path(b, "update_metadata.upb.c"),
    });
    module.addCSourceFile(.{
        .file = minitable_out.path(b, "update_metadata.upb_minitable.c"),
    });
    module.addCSourceFile(.{
        .file = b.path("src/c/upb_wrap.c"),
    });
    addSourceFiles(b, module, "third_party/protobuf", &deps.upb_sources);
    addSourceFiles(b, module, "third_party/protobuf", &deps.upb_bootstrap_sources);
    addSourceFiles(b, module, "third_party/protobuf", &deps.utf8_range_sources);
    addSourceFiles(b, module, "third_party/bzip2", &deps.bzip2_sources);
}

fn attachSystemPayloadDeps(
    b: *std.Build,
    module: *std.Build.Module,
    upb_out: std.Build.LazyPath,
    minitable_out: std.Build.LazyPath,
) void {
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
    module.linkSystemLibrary("bz2", .{});
}

fn attachPayloadDeps(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    upb_out: std.Build.LazyPath,
    minitable_out: std.Build.LazyPath,
) void {
    if (isWindowsTarget(target)) {
        attachVendoredPayloadDeps(b, module, upb_out, minitable_out);
    } else {
        attachSystemPayloadDeps(b, module, upb_out, minitable_out);
    }
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

    const upb_out: std.Build.LazyPath, const minitable_out: std.Build.LazyPath = blk: {
        if (isWindowsTarget(options.target)) {
            break :blk .{
                b.path("src/c"),
                b.path("src/c"),
            };
        } else {
            const protoc = b.addSystemCommand(&.{"protoc"});
            const uo = protoc.addPrefixedOutputDirectoryArg("--upb_out=", "proto_upb");
            const mo = protoc.addPrefixedOutputDirectoryArg("--upb_minitable_out=", "proto_minitable");
            protoc.addArg("--proto_path=proto");
            protoc.addArg("update_metadata.proto");
            break :blk .{ uo, mo };
        }
    };

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
    if (isWindowsTarget(options.target)) {
        translate_compress.addIncludePath(b.path("third_party/bzip2"));
    }

    const root_module = createRootModule(b, options, "src/main.zig");
    root_module.addOptions("build_options", build_options);
    attachPayloadDeps(b, root_module, options.target, upb_out, minitable_out);

    const zpayload_mod = createRootModule(b, options, "src/root.zig");
    attachPayloadDeps(b, zpayload_mod, options.target, upb_out, minitable_out);

    root_module.addImport("upb", translate_upb.createModule());
    root_module.addImport("compress", translate_compress.createModule());
    zpayload_mod.addImport("upb", translate_upb.createModule());
    zpayload_mod.addImport("compress", translate_compress.createModule());

    const exe = createNamedExecutable(b, "zpayload-dumper", root_module);
    b.installArtifact(exe);
    addRunStep(b, "run", "Run zpayload-dumper", exe);

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
