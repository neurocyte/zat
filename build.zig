const std = @import("std");

pub fn build(b: *std.Build) void {
    const release = b.option(bool, "package_release", "Build all release targets") orelse false;
    const strip = b.option(bool, "strip", "Disable debug information (default: no)");
    const pie = b.option(bool, "pie", "Produce an executable with position independent code (default: none)");

    const run_step = b.step("run", "Run the app");

    return (if (release) &build_release else &build_development)(
        b,
        run_step,
        strip,
        pie,
    );
}

fn build_development(
    b: *std.Build,
    run_step: *std.Build.Step,
    strip: ?bool,
    pie: ?bool,
) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    return build_exe(
        b,
        run_step,
        target,
        optimize,
        .{},
        strip orelse false,
        pie,
    );
}

fn build_release(
    b: *std.Build,
    run_step: *std.Build.Step,
    strip: ?bool,
    pie: ?bool,
) void {
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };
    const optimize = .ReleaseFast;

    var version = std.ArrayList(u8).init(b.allocator);
    defer version.deinit();
    gen_version(b, version.writer()) catch unreachable;
    const write_file_step = b.addWriteFiles();
    const version_file = write_file_step.add("version", version.items);
    b.getInstallStep().dependOn(&b.addInstallFile(version_file, "version").step);

    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        var triple = std.mem.splitScalar(u8, t.zigTriple(b.allocator) catch unreachable, '-');
        const arch = triple.next() orelse unreachable;
        const os = triple.next() orelse unreachable;
        const target_path = std.mem.join(b.allocator, "-", &[_][]const u8{ os, arch }) catch unreachable;

        build_exe(
            b,
            run_step,
            target,
            optimize,
            .{ .dest_dir = .{ .override = .{ .custom = target_path } } },
            strip orelse true,
            pie,
        );
    }
}

pub fn build_exe(
    b: *std.Build,
    run_step: *std.Build.Step,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    exe_install_options: std.Build.Step.InstallArtifact.Options,
    strip: bool,
    pie: ?bool,
) void {

    const clap_dep = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const ansi_term_dep = b.dependency("ansi-term", .{ .target = target, .optimize = optimize });
    const themes_dep = b.dependency("themes", .{});
    const syntax_dep = b.dependency("syntax", .{ .target = target, .optimize = optimize });
    const thespian_dep = b.dependency("thespian", .{});

    const exe = b.addExecutable(.{
        .name = "zat",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    if (pie) |value| exe.pie = value;
    exe.root_module.addImport("syntax", syntax_dep.module("syntax"));
    exe.root_module.addImport("theme", themes_dep.module("theme"));
    exe.root_module.addImport("themes", themes_dep.module("themes"));
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    exe.root_module.addImport("ansi-term", ansi_term_dep.module("ansi-term"));
    exe.root_module.addImport("cbor", b.createModule(.{ .root_source_file = thespian_dep.path("src/cbor.zig") }));
    const exe_install = b.addInstallArtifact(exe, exe_install_options);
    b.getInstallStep().dependOn(&exe_install.step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}

fn gen_version(b: *std.Build, writer: anytype) !void {
    var code: u8 = 0;

    const describe = try b.runAllowFail(&[_][]const u8{ "git", "describe", "--always", "--tags" }, &code, .Ignore);
    const diff_ = try b.runAllowFail(&[_][]const u8{ "git", "diff", "--stat", "--patch", "HEAD" }, &code, .Ignore);
    const diff = std.mem.trimRight(u8, diff_, "\r\n ");
    const version = std.mem.trimRight(u8, describe, "\r\n ");

    try writer.print("{s}{s}", .{ version, if (diff.len > 0) "-dirty" else "" });
}
