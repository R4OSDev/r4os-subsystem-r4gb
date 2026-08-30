const std = @import("std");

pub fn build(b: *std.Build) void {
    const sdk_build = b.lazyImport(@This(), "r4os_sdk") orelse return;
    const sdk_dep = b.dependencyFromBuildZig(sdk_build, .{});
    const sdk = sdk_build.sdk(b, sdk_dep, .{});
    _ = sdk.addR4MF(b.path("module.R4MF"));

    const core = b.createModule(.{
        .root_source_file = b.path("src/core.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const unit_root = b.createModule(.{
        .root_source_file = b.path("Tests/unit_test.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    unit_root.addImport("core", core);
    const unit_tests = b.addTest(.{ .root_module = unit_root });
    const run_unit_tests = b.addRunArtifact(unit_tests);

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

    const test_step = b.step("test", "Build R4GB and run deterministic owner tests");
    test_step.dependOn(b.getInstallStep());
    test_step.dependOn(&run_unit_tests.step);

    const reference_step = b.step("reference-test", "Validate all available pinned SM83 vectors and open ROM fixtures");
    reference_step.dependOn(&run_references.step);
}
