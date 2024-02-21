const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const tree_sitter_dep = b.dependency("tree-sitter", .{ .target = target, .optimize = optimize });
    const clap_dep = b.dependency("clap", .{ .target = target, .optimize = optimize });
    const themes_dep = b.dependency("themes", .{});

    const syntax_mod = b.createModule(.{
        .root_source_file = .{ .path = "src/syntax.zig" },
        .imports = &.{
            .{ .name = "tree-sitter", .module = tree_sitter_dep.module("tree-sitter") },
            file_module(b, tree_sitter_dep, "tree-sitter-agda/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-bash/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-c-sharp/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-c/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-cpp/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-css/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-diff/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-dockerfile/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-git-rebase/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-gitcommit/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-go/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-fish/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-haskell/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-html/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-java/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-javascript/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-jsdoc/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-json/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-lua/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-make/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-markdown/tree-sitter-markdown/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-markdown/tree-sitter-markdown-inline/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-nasm/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-ninja/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-nix/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-ocaml/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-openscad/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-org/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-php/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-python/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-purescript/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-regex/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-ruby/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-rust/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-ssh-config/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-scala/queries/scala/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-scheme/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-toml/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-typescript/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-xml/dtd/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-xml/xml/queries/highlights.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-zig/queries/highlights.scm"),

            file_module(b, tree_sitter_dep, "tree-sitter-cpp/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-gitcommit/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-html/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-javascript/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-lua/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-markdown/tree-sitter-markdown-inline/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-markdown/tree-sitter-markdown/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-nasm/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-nix/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-openscad/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-php/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-purescript/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-purescript/vim_queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-rust/queries/injections.scm"),
            file_module(b, tree_sitter_dep, "tree-sitter-zig/queries/injections.scm"),
        },
    });

    const exe = b.addExecutable(.{
        .name = "zat",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("syntax", syntax_mod);
    exe.root_module.addImport("theme", themes_dep.module("theme"));
    exe.root_module.addImport("themes", themes_dep.module("themes"));
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}

fn file_module(b: *std.Build, dep: *std.Build.Dependency, comptime sub_path: []const u8) std.Build.Module.Import {
    return .{
        .name = sub_path,
        .module = b.createModule(.{
            .root_source_file = dep.path(sub_path),
        }),
    };
}
