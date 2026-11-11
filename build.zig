//! meja — a cross-platform database management app.
//!
//! Layout of this build:
//!
//!   meja (module)      src/root.zig   — the reusable core library.
//!                                     Everything platform-agnostic lives
//!                                     here: SQL text utilities, the typed
//!                                     value layer, schema introspection and
//!                                     the query engine.
//!
//!   meja-cli (exe)     src/cli/       — terminal frontend. Needs no
//!                                     display server, so it builds and
//!                                     tests on Linux, macOS and Windows
//!                                     without a GUI session.
//!
//!   meja-gui (exe)     src/gui/       — glinlandui frontend. Optional:
//!                                     `-Dgui=false` drops it so the CLI
//!                                     still builds on a box with no
//!                                     Wayland toolchain installed.
//!
//! Both frontends depend on `meja` — neither contains data-access logic of
//! its own, which is what keeps them in sync.
//!
//! ## Dependency wiring
//!
//! `databases` (ruangsql) is resolved through `b.dependency(...)` and
//! exposes a single module named `databases`. It carries the sqlite3 /
//! libpq / openssl link line for whatever target we hand it, so this
//! build.zig never has to name a system library directly.
//!
//! `-Ddb_used` is forwarded verbatim: `"sqlite"` (default) links nothing
//! but sqlite3; `"sqlite,postgres"` additionally compiles the libpq
//! backend. Keeping sqlite as the default is what makes the CI matrix
//! cheap — a Linux runner has no libpq by default.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Frontend toggles. Both default to on; turning either off produces a
    // leaner build (and a leaner CI job) without touching source.
    const build_gui = b.option(
        bool,
        "gui",
        "Build the glinlandui GUI executable (default: true)",
    ) orelse true;

    // Comma-separated backend list forwarded to ruangsql. See
    // src/root.zig for how the app branches on this at comptime.
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

    // --- a dump tool: renders a real frame and prints what it drew ---
    // Not installed; run it with `zig build inspect -- <db>`. It is how
    // the GUI was verified without a human at the screen.
    //
    // GUI-only, like the executable above it: it drives the REAL draw
    // functions, so there is nothing to build without glinlandui. The
    // old version reached for `glinlandui_dep.?` unconditionally, which
    // made `zig build test -Dgui=false` — the documented way to build on
    // a box with no Wayland toolchain — abort in build.zig itself,
    // before compiling anything.
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

    // --- tests ---
    // The core is tested directly against the `meja` module. It has no
    // dependency on any frontend, so these tests pass on every platform
    // with no display server.
    const core_tests = b.addTest(.{ .root_module = meja_mod });
    const run_core_tests = b.addRunArtifact(core_tests);

    // The CLI frontend gets its own test binary: `zig build test` exercises
    // argument parsing, formatting and the interactive REPL against a real
    // in-memory database.
    const cli_tests = b.addTest(.{ .root_module = cli_mod });
    const run_cli_tests = b.addRunArtifact(cli_tests);

    const test_step = b.step("test", "Run core + CLI tests");
    test_step.dependOn(&run_core_tests.step);
    test_step.dependOn(&run_cli_tests.step);

    // GUI tests are opt-in and separate: they need the glinlandui
    // dependency to configure, and a GUI-less CI runner can skip them
    // with `-Dgui=false` (in which case this step is not registered).
    if (gui_mod) |gm| {
        const gui_tests = b.addTest(.{ .root_module = gm });
        const run_gui_tests = b.addRunArtifact(gui_tests);
        const gui_test_step = b.step("test-gui", "Run GUI unit tests (headless)");
        gui_test_step.dependOn(&run_gui_tests.step);
        test_step.dependOn(&run_gui_tests.step);
    }
}
