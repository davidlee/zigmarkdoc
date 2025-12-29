const std = @import("std");

pub fn build(b: *std.Build) void {
  const target = b.standardTargetOptions(.{});
  const optimize = b.standardOptimizeOption(.{});

  // Library module
  const lib_mod = b.createModule(.{
    .root_source_file = b.path("src/lib.zig"),
    .target = target,
    .optimize = optimize,
  });

  // Main executable module
  const exe_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
  });
  exe_mod.addImport("lib", lib_mod);

  const exe = b.addExecutable(.{
    .name = "zigmarkdoc",
    .root_module = exe_mod,
  });
  b.installArtifact(exe);

  // Run command
  const run_cmd = b.addRunArtifact(exe);
  run_cmd.step.dependOn(b.getInstallStep());
  if (b.args) |args| {
    run_cmd.addArgs(args);
  }
  const run_step = b.step("run", "Run zigmarkdoc");
  run_step.dependOn(&run_cmd.step);

  // Unit tests for lib
  const lib_test_mod = b.createModule(.{
    .root_source_file = b.path("src/lib.zig"),
    .target = target,
    .optimize = optimize,
  });
  const lib_tests = b.addTest(.{
    .root_module = lib_test_mod,
  });
  const run_lib_tests = b.addRunArtifact(lib_tests);

  // Unit tests for main
  const exe_test_mod = b.createModule(.{
    .root_source_file = b.path("src/main.zig"),
    .target = target,
    .optimize = optimize,
  });
  exe_test_mod.addImport("lib", lib_mod);
  const exe_tests = b.addTest(.{
    .root_module = exe_test_mod,
  });
  const run_exe_tests = b.addRunArtifact(exe_tests);

  const test_step = b.step("test", "Run unit tests");
  test_step.dependOn(&run_lib_tests.step);
  test_step.dependOn(&run_exe_tests.step);
}
