//! meja — a cross-platform database management app.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Frontend toggles.
    const build_gui = b.option(
        bool,
        "gui",
        "Build the glinlandui GUI executable (default: true)",
    ) orelse true;

    // Comma-separated backend list forwarded to ruangsql.
    const db_used = b.option(
        []const u8,
        "db_used",
        "Comma-separated database backends: 'sqlite' (default) or 'sqlite,postgres'",
    ) orelse "sqlite";

    // --- dependency: databases (ruangsql) ---
    const databases_dep = b.dependency("databases", .{
        .target = target,
        .optimize = optimize,
        .db_used = db_used,
    });
    const databases_mod = databases_dep.module("databases");

    // --- dependency: glinlandui (GUI only) ---
    var glinlandui_dep: ?*std.Build.Dependency = null;
    if (build_gui) {
        glinlandui_dep = b.dependency("glinlandui", .{
            .target = target,
            .optimize = optimize,
        });
    }

    // --- core library module ---
    const meja_mod = b.addModule("meja", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    meja_mod.addImport("databases", databases_mod);

    // --- CLI executable ---
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("src/cli/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "meja", .module = meja_mod },
            .{ .name = "databases", .module = databases_mod },
        },
    });
    const cli_exe = b.addExecutable(.{
        .name = "meja",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);

    // --- GUI executable (optional) ---
    var gui_mod: ?*std.Build.Module = null;
    var gui_exe: ?*std.Build.Step.Compile = null;
    if (glinlandui_dep != null) {
        gui_mod = b.createModule(.{
            .root_source_file = b.path("src/gui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "meja", .module = meja_mod },
                .{ .name = "databases", .module = databases_mod },
                .{ .name = "glinlandui", .module = glinlandui_dep.?.module("glinlandui") },
            },
        });
        const ge = b.addExecutable(.{
            .name = "meja-gui",
            .root_module = gui_mod.?,
        });
        gui_exe = ge;
        b.installArtifact(ge);
    }

    // --- run steps ---
    const run_cli = b.addRunArtifact(cli_exe);
    run_cli.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cli.addArgs(args);
    const run_cli_step = b.step("run", "Run the meja CLI");
    run_cli_step.dependOn(&run_cli.step);

    if (gui_exe) |ge| {
        const run_gui = b.addRunArtifact(ge);
        run_gui.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_gui.addArgs(args);
        const run_gui_step = b.step("run-gui", "Run the meja GUI");
        run_gui_step.dependOn(&run_gui.step);
    }

    // --- a dump tool: renders a real frame and prints what it drew --- Not installed; run it with `zig build inspect -- <db>`.
    if (glinlandui_dep) |gdep| {
        const inspect = b.addExecutable(.{
            .name = "meja-inspect",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/gui/inspect.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "meja", .module = meja_mod },
                    .{ .name = "databases", .module = databases_mod },
                    .{ .name = "glinlandui", .module = gdep.module("glinlandui") },
                },
            }),
        });
        const run_inspect = b.addRunArtifact(inspect);
        if (b.args) |args| run_inspect.addArgs(args);
        const inspect_step = b.step("inspect", "Render one frame and print it");
        inspect_step.dependOn(&run_inspect.step);
    }

    // --- tests --- The core is tested directly against the `meja` module.
    const core_tests = b.addTest(.{ .root_module = meja_mod });
    const run_core_tests = b.addRunArtifact(core_tests);

    // The CLI frontend gets its own test binary: `zig build test` exercises argument parsing, formatting and the interactive REPL against a real in-memory.
    const cli_tests = b.addTest(.{ .root_module = cli_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run core + CLI tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    // GUI tests are opt-in and separate: they need the glinlandui dependency to configure, and a GUI-less CI runner can skip them with `-Dgui=false` (in.
    if (gui_mod) |gm| {
        const gui_tests = b.addTest(.{ .root_module = gm });
        const run_gui_tests = b.addRunArtifact(gui_tests);
        const gui_test_step = b.step("test-gui", "Run GUI unit tests (headless)");
        gui_test_step.dependOn(&run_gui_tests.step);
        test_step.dependOn(&run_gui_tests.step);
    }

    // --- lint: zginlint (github.com/ginwa123/zglint) --- Pinned in build.zig.zon.
    const zginlint_dep = b.dependency("zginlint", .{
        .target = target,
        .optimize = optimize,
    });
    const zginlint_exe = zginlint_dep.artifact("zginlint");
    const install_zginlint = b.addInstallArtifact(zginlint_exe, .{});
    b.step("zginlint", "Build the zginlint CLI into zig-out/bin/zginlint")
        .dependOn(&install_zginlint.step);

    // The scope the gate covers.
    const zginlint_scope = [_][]const u8{ "src", "build.zig" };

    // `has_side_effects` is load-bearing: a Run step is keyed by its binary and argv, NOT by the tree it reads, so without it a rerun skips the scan.
    const zginlint_check = b.step("zginlint:check", "Enforce the zginlint rules on the tree (zero findings)");
    const run_zginlint_check = b.addRunArtifact(zginlint_exe);
    run_zginlint_check.setCwd(b.path("."));
    run_zginlint_check.addArgs(&.{ "--max-comment-lines", "1" });
    run_zginlint_check.addArgs(&zginlint_scope);
    run_zginlint_check.has_side_effects = true;
    zginlint_check.dependOn(&run_zginlint_check.step);

    // ---- size: no .zig file over 3000 lines; POSIX sh, so an opt-in step ----
    const lines_check = b.step("lines:check", "Fail if any .zig file exceeds 3000 lines");
    const run_lines_check = b.addSystemCommand(&.{
        "sh", "-c",
        "find src -name '*.zig' -exec wc -l {} + | awk '$1 > 3000 && $2 != \"total\" { print $2 \": \" $1 \" lines (max 3000)\"; bad=1 } END { exit bad }'",
    });
    run_lines_check.has_side_effects = true;
    lines_check.dependOn(&run_lines_check.step);
}
