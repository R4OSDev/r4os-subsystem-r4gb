const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));
    const host_r4os = sdk.createR4osModule(b.graph.host, .Debug);

    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    core.addImport("r4os", host_r4os);
    const unit_root = b.createModule(.{
        .root_source_file = b.path("Tests/unit_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    unit_root.addImport("core", core);
    const unit_tests = b.addTest(.{ .root_module = unit_root });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    // Keep the timing-sensitive APU model tests in the owner gate even though
    // production imports deliberately do not expose source-local test blocks.
    const apu_test_root = b.createModule(.{
        .root_source_file = b.path("src/apu.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const apu_tests = b.addTest(.{ .root_module = apu_test_root });
    const run_apu_tests = b.addRunArtifact(apu_tests);

    const video_host_root = b.createModule(.{
        .root_source_file = b.path("Tests/video_host_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    video_host_root.addImport("core", core);
    video_host_root.addImport("r4os", host_r4os);
    const video_host_tests = b.addTest(.{ .root_module = video_host_root });
    const run_video_host_tests = b.addRunArtifact(video_host_tests);

    const runtime_adapter_root = b.createModule(.{
        .root_source_file = b.path("Tests/runtime_adapter_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    runtime_adapter_root.addImport("core", core);
    runtime_adapter_root.addImport("r4os", host_r4os);
    const runtime_adapter_tests = b.addTest(.{ .root_module = runtime_adapter_root });
    const run_runtime_adapter_tests = b.addRunArtifact(runtime_adapter_tests);

    const persistence_root = b.createModule(.{
        .root_source_file = b.path("Tests/persistence_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    persistence_root.addImport("core", core);
    const persistence_tests = b.addTest(.{ .root_module = persistence_root });
    const run_persistence_tests = b.addRunArtifact(persistence_tests);

    const product_host_root = b.createModule(.{
        .root_source_file = b.path("Tests/product_host_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    product_host_root.addImport("core", core);
    product_host_root.addImport("r4os", host_r4os);
    const product_host_tests = b.addTest(.{ .root_module = product_host_root });
    const run_product_host_tests = b.addRunArtifact(product_host_tests);

    const reference_root = b.createModule(.{
        .root_source_file = b.path("Tests/reference_harness.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    reference_root.addImport("core", core);
    const reference_harness = b.addExecutable(.{ .name = "r4gb-reference-harness", .root_module = reference_root });
    const run_references = b.addRunArtifact(reference_harness);
    run_references.setCwd(b.path("."));
    run_references.addArg(b.option([]const u8, "gb-reference-root", "Game Boy reference root; absent material is skipped") orelse "../../../ExFiles/Reference/GameBoy");
    const reference_suite = b.option([]const u8, "gb-reference-suite", "Run only one reference suite by manifest id");
    if (reference_suite) |suite| run_references.addArg(suite);
    if (b.option([]const u8, "gb-reference-case", "Run one path from a machine ROM selection")) |case_path| {
        if (reference_suite == null) run_references.addArg("");
        run_references.addArg(case_path);
    }

    const cartridge_probe_root = b.createModule(.{
        .root_source_file = b.path("Tests/cartridge_probe.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    cartridge_probe_root.addImport("core", core);
    const cartridge_probe = b.addExecutable(.{ .name = "r4gb-cartridge-probe", .root_module = cartridge_probe_root });
    const run_cartridge_probe = b.addRunArtifact(cartridge_probe);
    run_cartridge_probe.addArg(b.option([]const u8, "gb-cartridge", "Explicit local cartridge image to validate") orelse "");

    const test_step = b.step("test", "Build R4GB and run deterministic owner tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_unit_tests.step);
    test_step.dependOn(&run_apu_tests.step);
    test_step.dependOn(&run_video_host_tests.step);
    test_step.dependOn(&run_runtime_adapter_tests.step);
    test_step.dependOn(&run_persistence_tests.step);
    test_step.dependOn(&run_product_host_tests.step);

    const reference_step = b.step("reference-test", "Validate all available pinned SM83 vectors and open ROM fixtures");
    reference_step.dependOn(&run_references.step);

    const cartridge_step = b.step("cartridge-test", "Validate one explicitly supplied local cartridge without modifying it");
    cartridge_step.dependOn(&run_cartridge_probe.step);
}
