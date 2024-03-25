const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const clap_dep = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const ansi_term_dep = b.dependency("ansi-term", .{ .target = target, .optimize = optimize });
    const themes_dep = b.dependency("themes", .{});
    const syntax_dep = b.dependency("syntax", .{ .target = target, .optimize = optimize });
    const thespian_dep = b.dependency("thespian", .{});

    const exe = b.addExecutable(.{
        .name = "zat",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("syntax", syntax_dep.module("syntax"));
    exe.root_module.addImport("theme", themes_dep.module("theme"));
    exe.root_module.addImport("themes", themes_dep.module("themes"));
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    exe.root_module.addImport("ansi-term", ansi_term_dep.module("ansi-term"));
    exe.root_module.addImport("cbor", b.createModule(.{ .root_source_file = thespian_dep.path("src/cbor.zig") }));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
