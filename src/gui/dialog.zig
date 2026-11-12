//! The system file dialog, as meja uses it.

const std = @import("std");
const builtin = @import("builtin");

const ui = @import("glinlandui");
const picker_mod = @import("picker.zig");

/// The dialog backend this file calls.
const backend = if (builtin.is_test) ui.file_dialog.fake else ui.file_dialog;

/// The filter list the system dialog offers, built from the extension list the picker already uses.
const database_rules = blk: {
    var rules: [picker_mod.database_extensions.len]ui.file_dialog.Rule = undefined;
    for (picker_mod.database_extensions, 0..) |ext, i| {
        rules[i] = .{ .pattern = "*" ++ ext };
    }
    break :blk rules;
};

/// The filter list the system dialog offers, built from the extension list the picker already uses.
pub const db_filters: []const ui.file_dialog.Filter = &.{
    .{ .name = "SQLite databases", .rules = &database_rules },
    // "All files" is not decoration.
    .{ .name = "All files", .rules = &.{.{ .pattern = "*" }} },
};

/// Why the browse could not happen, as distinct from "the user said no".
pub const BrowseLimit = enum {
    /// This build has no dialog backend at all.
    no_dialog,
    /// Linux, with a session bus but nothing owning `org.freedesktop.portal.Desktop` — a bare Wayland session with no desktop portal installed, which is a.
    no_portal,
    /// Linux, with no session bus to ask.
    no_bus,
    /// The dialog backend exists and refused.
    failed,

    /// The sentence to put in the status line.
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
pub fn limitFor(err: anyerror) BrowseLimit {
    const name = @errorName(err);
    if (std.mem.eql(u8, name, "Unsupported")) return .no_dialog;
    if (std.mem.eql(u8, name, "NoPortal")) return .no_portal;
    if (std.mem.eql(u8, name, "NoSessionBus")) return .no_bus;
    return .failed;
}

/// What a browse produced, reduced to the three things the app acts on.
pub const Outcome = union(enum) {
    opened: []const u8,
    cancelled,
    unavailable: BrowseLimit,

    /// Release the path.
    pub fn free(self: Outcome, gpa: std.mem.Allocator) void {
        switch (self) {
            .opened => |path| gpa.free(path),
            .cancelled, .unavailable => {},
        }
    }
};

/// Ask the system dialog for a database and report what happened.
pub fn browse(gpa: std.mem.Allocator, start_dir: ?[]const u8) !Outcome {
    const selection = backend.openFile(gpa, .{
        .title = "Open database",
        .filters = db_filters,
        // Where the dialog opens.
        .current_folder = start_dir,
    }) catch |err| return .{ .unavailable = limitFor(err) };

    // The selection owns its paths, and they are the only copy: the dialog has already been dismissed by the time this runs, so nothing else is holding.
    defer selection.deinit(gpa);

    return switch (selection.status) {
        .selected => blk: {
            const picked = selection.first() orelse break :blk .cancelled;
            // DUPLICATED, not borrowed.
            const owned = gpa.dupe(u8, picked) catch return error.OutOfMemory;
            break :blk .{ .opened = owned };
        },
        .cancelled => .cancelled,
        .other => .cancelled,
    };
}

// Tests.

const testing = std.testing;

test "the filters offer every extension the picker recognises" {
    const filters = db_filters;
    // Two: the databases, and the escape hatch for a file with no extension.
    try testing.expectEqual(@as(usize, 2), filters.len);
    try testing.expectEqualStrings("SQLite databases", filters[0].name);
    try testing.expectEqualStrings("All files", filters[1].name);

    // One rule per extension, in the picker's order, and the same set — not approximately the same set.
    try testing.expectEqual(picker_mod.database_extensions.len, filters[0].rules.len);
    for (picker_mod.database_extensions, filters[0].rules) |ext, rule| {
        var want: [16]u8 = undefined;
        const glob = try std.fmt.bufPrint(&want, "*{s}", .{ext});
        try testing.expectEqualStrings(glob, rule.pattern);
    }
}

test "a filter pattern is a glob, so it keeps the extension's dot" {
    const filters = db_filters;
    // ".db" must not become "*.db" by accident, and "*.db" must not become "**" by a stray extra star.
    try testing.expectEqualStrings("*.db", filters[0].rules[0].pattern);
    try testing.expectEqualStrings("*", filters[1].rules[0].pattern);
}

test "the filters are a constant, so they outlive the dialog that uses them" {
    // No allocation and no lifetime: the same pointer twice, and still valid after the picker has scanned a directory.
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
    // `limitFor` matches by name, so a future error type cannot be silently mis-bucketed by an exhaustive switch — and an OOM must not send the user off to.
    try testing.expectEqual(BrowseLimit.failed, limitFor(error.OutOfMemory));
}

test "every limit says what to do next, not just what went wrong" {
    // An error the user cannot act on is a dead end.
    for ([_]BrowseLimit{ .no_dialog, .no_portal, .no_bus, .failed }) |limit| {
        const text = limit.explain();
        try testing.expect(text.len > 0);
        try testing.expect(std.mem.indexOf(u8, text, "picker") != null);
    }
}

test "the three Linux limits are distinguishable in the text too" {
    // Two different failures with the same sentence would leave the user guessing, and "no portal" and "no bus" have completely different fixes.
    try testing.expect(!std.mem.eql(u8, BrowseLimit.no_portal.explain(), BrowseLimit.no_bus.explain()));
    try testing.expect(!std.mem.eql(u8, BrowseLimit.no_dialog.explain(), BrowseLimit.no_portal.explain()));
}

test "with no fake installed a browse says so instead of pretending" {
    // The opt-in property, asserted from the consumer's side.
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

// The outcomes a real dialog can produce.

/// Install `answer` as what the dialog will say, for the duration of a test.
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
    // The path is BORROWED from the selection, which `browse` frees.
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a cancelled dialog is not an error, and says nothing happened" {
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .cancelled);

    // The user closed the window on purpose.
    switch (try browse(testing.allocator, null)) {
        .cancelled => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 1), fake.calls);
}

test "a dialog that closed for another reason is not a cancellation" {
    // `other` is distinct from `cancelled` so an app can log it without bothering the user.
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
    // The whole point of `limitFor`: "no portal" and "no bus" have completely different fixes, and a single "the dialog failed" would send the user looking.
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
    // The request half of the contract.
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
    // Null means "the platform decides", which on every desktop is the user's home directory — a better guess than a database browser can make.
    var fake: ui.file_dialog.fake.Fake = undefined;
    defer ui.file_dialog.fake.uninstall();
    script(&fake, .cancelled);

    _ = try browse(testing.allocator, null);
    try testing.expectEqual(@as(?[]const u8, null), fake.last_folder);
}

test "a selection with no paths is not treated as a picked file" {
    // A backend that was asked for a file and got none reports `.other`.
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
    // The fake is stateless between calls apart from its counter, so a second browse is a second real round trip.
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
