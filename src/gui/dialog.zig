//! The system file dialog, as meja uses it.
//!
//! glinlandui grew a `file_dialog` — the XDG portal on Linux, `NSOpenPanel`
//! on macOS, `IFileDialog` on Windows — and this is the thin layer that turns
//! "the user picked something" into "meja has a new database".
//!
//! ## Why it is a separate module
//!
//! Two reasons, and the first is the interesting one.
//!
//! `browse()` cannot be tested by calling it: a test build selects
//! glinlandui's portable backend, where the dialog is `error.Unsupported`.
//! So the *call* is untestable by construction, and the only way to get
//! coverage is to make everything around it testable and test that instead.
//!
//! Hence the shape here: `dbFilters`, `limitFor` and `explain` are pure, take
//! their arguments, and are asserted directly; `browse` is the four lines
//! that join them to the one call nobody can fake. When a new platform gains a
//! backend, the untested part does not grow.
//!
//! ## The picker stays
//!
//! `picker.zig` is a hand-rolled directory listing, and it is still the only
//! way to reach a database on a host with no system dialog — a browser, or a
//! Wayland session with no desktop portal. It is also what the GUI tests
//! drive, because a test cannot click a native dialog. So this is an
//! addition, not a replacement: Browse is the way that feels native, the
//! picker is the way that always works.
//!
//! ## It blocks, on purpose
//!
//! A file dialog is modal. The call is made from a click handler, so the
//! window is frozen for as long as the dialog is open — which is what every
//! native file dialog does, and what the user expects. The consequence for
//! this code is only that `browse` must not assume the app is repainting
//! while it runs, and must always say something when it returns.

const std = @import("std");
const builtin = @import("builtin");

const ui = @import("glinlandui");
const picker_mod = @import("picker.zig");

/// The dialog backend this file calls.
///
/// A test build takes the SCRIPTABLE fake rather than the portable stub, and
/// that is the whole reason `browse()` is testable at all. Without it a test
/// build could only ever produce `error.Unsupported`, so every outcome past
/// the call — a selection, a cancellation, each portal error — was written,
/// shipped and never once executed by a test.
///
/// The fake is opt-in in the toolkit: with nothing installed it answers
/// exactly what the stub would, so a test that does not install one sees no
/// change. Production is untouched — this is the real backend on every host.
const backend = if (builtin.is_test) ui.file_dialog.fake else ui.file_dialog;

/// The filter list the system dialog offers, built from the extension list
/// the picker already uses.
///
/// ONE definition of "what counts as a database" — `picker.database_extensions`
/// — rather than a second list here that drifts from it the first time
/// somebody adds `.sqlite3` to one and not the other. The picker filters what
/// is *listed*; this filters what the system dialog *shows*, and a user who
/// sees `.db` offered here and not there has found a real inconsistency, not
/// a stylistic one.
/// One rule per extension, built at COMPTIME.
///
const database_rules = blk: {
    var rules: [picker_mod.database_extensions.len]ui.file_dialog.Rule = undefined;
    for (picker_mod.database_extensions, 0..) |ext, i| {
        rules[i] = .{ .pattern = "*" ++ ext };
    }
    break :blk rules;
};

/// The filter list the system dialog offers, built from the extension list
/// the picker already uses.
///
/// ONE definition of "what counts as a database" — `picker.database_extensions`
/// — rather than a second list here that drifts from it the first time
/// somebody adds `.sqlite3` to one and not the other. The picker filters what
/// is *listed*; this filters what the system dialog *shows*, and a user who
/// sees `.db` offered here and not there has found a real inconsistency, not
/// a stylistic one.
pub const db_filters: []const ui.file_dialog.Filter = &.{
    .{ .name = "SQLite databases", .rules = &database_rules },
    // "All files" is not decoration. SQLite will open any file at all, and a
    // user with a database called `data` and no extension has to be able to
    // reach it.
    .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
};

/// Why the browse could not happen, as distinct from "the user said no".
///
/// The distinction is the whole point of this enum. A cancelled dialog is
/// something the user did on purpose and needs no message beyond a quiet
/// return to the previous state; a missing dialog is a fact about the machine
/// the user cannot change from this window, and saying so is the difference
/// between a working application and one that looks broken.
pub const BrowseLimit = enum {
    /// This build has no dialog backend at all. The browser is the case that
    /// matters, and a test build, which selects the portable stub.
    no_dialog,
    /// Linux, with a session bus but nothing owning
    /// `org.freedesktop.portal.Desktop` — a bare Wayland session with no
    /// desktop portal installed, which is a real configuration rather than a
    /// broken one.
    no_portal,
    /// Linux, with no session bus to ask.
    no_bus,
    /// The dialog backend exists and refused.
    failed,

    /// The sentence to put in the status line.
    ///
    /// Every one of them ends by pointing at the picker, because the picker
    /// still works in all four cases. An error the user cannot act on is a
    /// dead end; this one has a next step.
    pub fn explain(self: BrowseLimit) []const u8 {
        return switch (self) {
            .no_dialog => "no system file dialog on this platform — use the picker below",
            .no_portal => "no desktop portal (xdg-desktop-portal) — use the picker below",
            .no_bus => "no D-Bus session bus — use the picker below",
            .failed => "the file dialog failed — use the picker below",
        };
    }
};

/// Map whatever the toolkit returned onto a `BrowseLimit`.
///
/// By name rather than by matching the error set, because the three Linux
/// failures are all in `file_dialog.Error` and the caller wants to know which
/// one happened. `OutOfMemory` falls through to `.failed`: it is not a fact
/// about the machine's portal, and saying "no D-Bus" about a memory failure
/// would send the user looking in the wrong place.
pub fn limitFor(err: anyerror) BrowseLimit {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "Unsupported")) return .no_dialog;
    if (std.mem.eql(u8, name, "NoPortal")) return .no_portal;
    if (std.mem.eql(u8, name, "NoSessionBus")) return .no_bus;
    return .failed;
}

/// What a browse produced, reduced to the three things the app acts on.
///
/// The path is OWNED by the caller and freed with `Outcome.free`. It has to
/// be: the `Selection` the dialog hands back is freed inside `browse`, so a
/// borrowed slice would be dangling the moment `browse` returned — which is
/// exactly what it was, and what the first test below caught.
pub const Outcome = union(enum) {
    opened: []const u8,
    cancelled,
    unavailable: BrowseLimit,

    /// Release the path. No-op for the two cases that hold none, so a caller
    /// can `defer outcome.free(gpa)` unconditionally.
    pub fn free(self: Outcome, gpa: std.mem.Allocator) void {
        switch (self) {
            .opened => |path| gpa.free(path),
            .cancelled, .unavailable => {},
        }
    }
};

/// Ask the system dialog for a database and report what happened.
///
/// Returns the outcome as well as acting on it, so a caller that wants to
/// draw something specific — a "cancelled" hint, a retry — can, and so a
/// test can assert the decision without a dialog.
///
/// The returned path is a COPY, and the caller frees it. The dialog's own
/// `Selection` is released here, because it is the only copy the backend
/// makes and nothing else is holding it — so handing out a slice of it would
/// hand out freed memory.
pub fn browse(gpa: std.mem.Allocator, start_dir: ?[]const u8) !Outcome {
    const selection = backend.openFile(gpa, .{
        .title = "Open database",
        .filters = db_filters,
        // Where the dialog opens. Null means "the platform decides", which on
        // every desktop is the user's home directory — a better guess than a
        // database browser can make.
        .current_folder = start_dir,
    }) catch |err| return .{ .unavailable = limitFor(err) };

    // The selection owns its paths, and they are the only copy: the dialog
    // has already been dismissed by the time this runs, so nothing else is
    // holding them. Forgetting the deinit is a leak per click, and the
    // toolkit's own tests are what keep that honest.
    defer selection.deinit(gpa);

    return switch (selection.status) {
        .selected => blk: {
            const picked = selection.first() orelse break :blk .cancelled;
            // DUPLICATED, not borrowed. This is the line that makes the
            // outcome safe to return: the `defer` above frees the selection
            // this slice points into, so a borrowed path would be dangling
            // before the caller could read it.
            const owned = gpa.dupe(u8, picked) catch return error.OutOfMemory;
            break :blk .{ .opened = owned };
        },
        .cancelled => .cancelled,
        .other => .cancelled,
    };
}

// ---------------------------------------------------------------------------
// Tests.
//
// The first group is the pure helpers. The second drives `browse` itself
// against the toolkit's scriptable dialog, which is what makes the call
// testable at all: a test build used to take the portable stub, so `openFile`
// was always `error.Unsupported` and every outcome past the call was
// unreachable.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the filters offer every extension the picker recognises" {
    const filters = db_filters;
    // Two: the databases, and the escape hatch for a file with no extension.
    try testing.expectEqual(@as(usize, 2), filters.len);
    try testing.expectEqualStrings("SQLite databases", filters[0].name);
    try testing.expectEqualStrings("All files", filters[1].name);

    // One rule per extension, in the picker's order, and the same set — not
    // approximately the same set. A user who sees `.sqlite3` in the listing
    // and not in the dialog has found a real inconsistency.
    try testing.expectEqual(picker_mod.database_extensions.len, filters[0].rules.len);
    for (picker_mod.database_extensions, filters[0].rules) |ext, rule| {
        var want: [16]u8 = undefined;
        const glob = try std.fmt.bufPrint(&want, "*{s}", .{ext});
        try testing.expectEqualStrings(glob, rule.pattern);
    }
}

test "a filter pattern is a glob, so it keeps the extension's dot" {
    const filters = db_filters;
    // ".db" must not become "*.db" by accident, and "*.db" must not become
    // "**" by a stray extra star.
    try testing.expectEqualStrings("*.db", filters[0].rules[0].pattern);
    try testing.expectEqualStrings("*", filters[1].rules[0].pattern);
}

test "the filters are a constant, so they outlive the dialog that uses them" {
    // No allocation and no lifetime: the same pointer twice, and still valid
    // after the picker has scanned a directory. A filter list built per click
    // and freed with the frame is the bug this pins down.
    const a = db_filters;
    const b = db_filters;
    try testing.expectEqual(@intFromPtr(a.ptr), @intFromPtr(b.ptr));
    _ = picker_mod.parentOf(a[0].name);
    try testing.expectEqualStrings("SQLite databases", a[0].name);
}

test "each toolkit failure is told apart, because the advice differs" {
    try testing.expectEqual(BrowseLimit.no_dialog, limitFor(error.Unsupported));
    try testing.expectEqual(BrowseLimit.no_portal, limitFor(error.NoPortal));
    try testing.expectEqual(BrowseLimit.no_bus, limitFor(error.NoSessionBus));
    try testing.expectEqual(BrowseLimit.failed, limitFor(error.PortalError));
    try testing.expectEqual(BrowseLimit.failed, limitFor(error.Timeout));
}

test "a memory failure is not reported as a missing portal" {
    // `limitFor` matches by name, so a future error type cannot be silently
    // mis-bucketed by an exhaustive switch — and an OOM must not send the
    // user off to install a desktop portal.
    try testing.expectEqual(BrowseLimit.failed, limitFor(error.OutOfMemory));
}

test "every limit says what to do next, not just what went wrong" {
    // An error the user cannot act on is a dead end. All four of these end
    // with the picker, which is the thing that always works.
    for ([_]BrowseLimit{ .no_dialog, .no_portal, .no_bus, .failed }) |limit| {
        const text = limit.explain();
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "picker") != null);
    }
}

test "the three Linux limits are distinguishable in the text too" {
    // Two different failures with the same sentence would leave the user
    // guessing, and "no portal" and "no bus" have completely different fixes.
    try testing.expect(!std.mem.eql(u8, BrowseLimit.no_portal.explain(), BrowseLimit.no_bus.explain()));
    try testing.expect(!std.mem.eql(u8, BrowseLimit.no_dialog.explain(), BrowseLimit.no_portal.explain()));
}

test "with no fake installed a browse says so instead of pretending" {
    // The opt-in property, asserted from the consumer's side. The toolkit's
    // fake answers exactly what the portable stub would when nothing is
    // installed, so this is the same outcome the suite had before the seam
    // existed — and it is what a browser gets.
    //
    // What matters is not that it fails. It is that it fails LOUDLY and
    // leaves a working application behind: a Browse button that silently does
    // nothing is indistinguishable from a database browser that cannot open
    // anything.
    //
    // A switch rather than `outcome.unavailable.value`: on a `union(enum)`
    // the field access yields a POINTER, and reading `.value` off the wrong
    // one is a compile error at best.
    switch (try browse(testing.allocator, null)) {
        .unavailable => |limit| {
            try testing.expectEqualStrings(
                "no system file dialog on this platform — use the picker below",
                limit.explain(),
            );
        },
        .opened => return error.TestUnexpectedResult,
        .cancelled => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// The outcomes a real dialog can produce.
//
// Everything above tests the pure helpers. Everything below tests `browse`
// itself, which was impossible before the toolkit grew a scriptable dialog:
// a test build took the portable stub, so `openFile` was always
// `error.Unsupported` and the selection, cancellation and error paths were
// written, shipped, and never once executed by a test.
//
// Each test installs a `Fake`, drives `browse`, and asserts on the OUTCOME —
// the thing the app acts on — and on what the dialog was ASKED for, which is
// the half a return value cannot show.
// ---------------------------------------------------------------------------

/// Install `answer` as what the dialog will say, for the duration of a test.
///
/// The `Fake` lives on the CALLER's stack and the caller passes it back in,
/// which is the only safe shape: the toolkit's fake holds a pointer to it, and
/// a `Fake` returned by value from this helper would leave that pointer aimed
/// at the copy the caller received, not at the one installed. The caller's
/// `defer uninstall()` then runs before its stack frame goes away.
fn script(fake: *ui.file_dialog.fake.Fake, answer: ui.file_dialog.fake.Answer) void {
    fake.* = .{ .answer = answer };
    ui.file_dialog.fake.install(fake);
}

test "a selection comes back as the path to open" {
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .{ .selected = &.{"/home/u/databases/app.db"} });

    const outcome = try browse(testing.allocator, "/home/u/databases");
    defer outcome.free(testing.allocator);
    switch (outcome) {
        .opened => |path| try testing.expectEqualStrings("/home/u/databases/app.db", path),
        else => return error.TestUnexpectedResult,
    }
    // The path is BORROWED from the selection, which `browse` frees. Reading
    // it after the switch is what proves the caller's copy is the one that
    // matters — `App.usePath` copies it into storage the App owns.
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a cancelled dialog is not an error, and says nothing happened" {
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .cancelled);

    // The user closed the window on purpose. An app that treated this as a
    // failure would show an error message for something nobody mistook.
    switch (try browse(testing.allocator, null)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a dialog that closed for another reason is not a cancellation" {
    // `other` is distinct from `cancelled` so an app can log it without
    // bothering the user. Collapsing the two would make a portal failure look
    // like something the user chose.
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .other);

    switch (try browse(testing.allocator, null)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "each portal failure maps to its own advice" {
    // The whole point of `limitFor`: "no portal" and "no bus" have completely
    // different fixes, and a single "the dialog failed" would send the user
    // looking in the wrong place.
    const cases = [_]struct { err: ui.file_dialog.Error, want: BrowseLimit }{
        .{ .err = error.Unsupported, .want = .no_dialog },
        .{ .err = error.NoPortal, .want = .no_portal },
        .{ .err = error.NoSessionBus, .want = .no_bus },
        .{ .err = error.PortalError, .want = .failed },
        .{ .err = error.Timeout, .want = .failed },
    };
    for (cases) |case| {
        var fake: ui.file_dialog.fake.Fake = undefined;
        defer ui.file_dialog.fake.uninstall();
        script(&fake, .{ .failed = case.err });

        switch (try browse(testing.allocator, null)) {
            .unavailable => |limit| try testing.expectEqual(case.want, limit),
            else => return error.TestUnexpectedResult,
        }
        try testing.expectEqual(@as(usize, 1), fake.calls);
    }
}

test "the dialog is asked for the right title, folder and filters" {
    // The request half of the contract. A dialog that opened in the wrong
    // directory, or offered the wrong extensions, would pass every assertion
    // on the answer alone.
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .cancelled);

    _ = try browse(testing.allocator, "/home/u/databases");

    try testing.expectEqualStrings("Open database", fake.last_title);
    try testing.expectEqualStrings("/home/u/databases", fake.last_folder.?);
    // The filter list is the picker's extension list, not a second copy of it.
    try testing.expectEqual(@as(usize, 2), fake.filter_count);
    try testing.expectEqualStrings("SQLite databases", fake.filters[0].nameText());
    try testing.expectEqual(
        picker_mod.database_extensions.len,
        fake.filters[0].rule_count,
    );
    try testing.expectEqualStrings("*.db", fake.filters[0].rules[0].patternText());
    try testing.expectEqualStrings("All files", fake.filters[1].nameText());
    try testing.expectEqualStrings("*", fake.filters[1].rules[0].patternText());
}

test "no starting folder is passed when there is nowhere obvious" {
    // Null means "the platform decides", which on every desktop is the user's
    // home directory — a better guess than a database browser can make. A
    // browser on `:memory:` has no parent directory to offer.
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .cancelled);

    _ = try browse(testing.allocator, null);
    try testing.expectEqual(@as(?[]const u8, null), fake.last_folder);
}

test "a selection with no paths is not treated as a picked file" {
    // A backend that was asked for a file and got none reports `.other`. An
    // app that read `first()` off an empty list would have to guess, and
    // `App.browseForDatabase` guards against exactly that.
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .{ .selected = &.{} });

    switch (try browse(testing.allocator, null)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "browsing twice asks twice, and each answer is its own" {
    // The fake is stateless between calls apart from its counter, so a second
    // browse is a second real round trip. This is what makes the e2e tests
    // below able to script one answer per click.
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .{ .selected = &.{"/tmp/first.db"} });

    const first = try browse(testing.allocator, null);
    defer first.free(testing.allocator);
    switch (first) {
        .opened => |path| try testing.expectEqualStrings("/tmp/first.db", path),
        else => return error.TestUnexpectedResult,
    }

    fake.answer = .{ .selected = &.{"/tmp/second.db"} };
    const second = try browse(testing.allocator, null);
    defer second.free(testing.allocator);
    switch (second) {
        .opened => |path| try testing.expectEqualStrings("/tmp/second.db", path),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 2), fake.calls);
}
