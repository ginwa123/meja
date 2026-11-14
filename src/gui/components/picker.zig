//! Choosing a database from inside the window.

const std = @import("std");
const ui = @import("glinlandui");
const Io = std.Io;

const editor = ui.text_editor;
const input = ui.components.input;

/// Longest path the picker holds, in bytes.
pub const path_capacity: usize = 512;

/// The listing shows this many entries.
pub const max_entries: usize = 200;

/// Extensions the picker offers as databases.
pub const database_extensions = [_][]const u8{
    ".db", ".db3", ".sqlite", ".sqlite3",
};

/// True when `name` ends in one of `database_extensions`, case insensitively, so `Users.DB` is offered alongside `users.db`.
pub fn looksLikeDatabase(name: []const u8) bool {
    for (database_extensions) |ext| {
        if (name.len < ext.len) continue;
        const tail = name[name.len - ext.len ..];
        if (std.ascii.eqlIgnoreCase(tail, ext)) return true;
    }
    return false;
}

/// One row in the listing.
pub const Candidate = struct {
    /// Base name only.
    name: []const u8,
    is_dir: bool,
};

/// The open-a-database panel's state.
pub const Picker = struct {
    /// Whether the panel is on screen at all.
    open: bool = false,

    /// The directory being listed.
    dir_buf: [path_capacity]u8 = undefined,
    dir_len: usize = 0,

    /// The typed path: the engine's field, bound to this picker's own buffer.
    field_buf: [path_capacity]u8 = undefined,
    field: input.Field = .{ .id = .{ .text = "picker.path" } },

    /// What `dir_buf` holds: subdirectories first, then database files, each group in name order so the listing does not reshuffle between scans.
    entries: std.ArrayList(Candidate) = .empty,

    /// Keyboard cursor over `entries`.
    cursor: usize = 0,

    /// Set when the directory could not be read.
    error_message: ?[]const u8 = null,

    /// Initialise IN PLACE, and bind the field to its own storage.
    pub fn init(self: *Picker) void {
        self.* = .{};
        self.field.bindTo(&self.field_buf);
    }

    pub fn deinit(self: *Picker, gpa: std.mem.Allocator) void {
        self.freeEntries(gpa);
    }

    pub fn dir(self: *const Picker) []const u8 {
        return self.dir_buf[0..self.dir_len];
    }

    /// Replace the listed directory.
    pub fn setDir(self: *Picker, path: []const u8) void {
        const n = @min(path.len, self.dir_buf.len);
        // @memmove, not @memcpy: `App.goUp` legitimately passes a slice of this very buffer (`parentOf(self.picker.dir())`), and @memcpy panics on aliasing.
        @memmove(self.dir_buf[0..n], path[0..n]);
        self.dir_len = n;
    }

    fn freeEntries(self: *Picker, gpa: std.mem.Allocator) void {
        for (self.entries.items) |c| gpa.free(c.name);
        self.entries.deinit(gpa);
        self.entries = .empty;
        self.cursor = 0;
    }

    /// Directories before files, then name order within each group.
    fn lessThan(_: void, a: Candidate, b: Candidate) bool {
        if (a.is_dir != b.is_dir) return a.is_dir;
        return std.mem.order(u8, a.name, b.name) == .lt;
    }

    /// Read the listed directory into `entries`.
    pub fn scan(self: *Picker, gpa: std.mem.Allocator, io: Io) void {
        self.freeEntries(gpa);
        self.error_message = null;

        const path = self.dir();
        // Not named `dir`: that is `Picker.dir()`, and shadowing it here is an error the compiler catches and a reader should not have to.
        const handle = std.Io.Dir.cwd().openDir(
            io,
            if (path.len == 0) "." else path,
            .{ .iterate = true },
        ) catch |err| {
            self.error_message = @errorName(err);
            return;
        };
        defer handle.close(io);

        var it = handle.iterate();
        while (it.next(io) catch null) |entry| {
            if (self.entries.items.len >= max_entries) break;
            const is_dir = entry.kind == .directory;
            if (!is_dir and !looksLikeDatabase(entry.name)) continue;
            const owned = gpa.dupe(u8, entry.name) catch break;
            self.entries.append(gpa, .{ .name = owned, .is_dir = is_dir }) catch {
                gpa.free(owned);
                break;
            };
        }

        std.sort.pdq(Candidate, self.entries.items, {}, lessThan);

        // ".." goes in first and is never sorted among the real entries.
        if (canGoUp(path)) {
            const parent = gpa.dupe(u8, "..") catch {
                self.cursor = 0;
                return;
            };
            self.entries.insert(gpa, 0, .{ .name = parent, .is_dir = true }) catch {
                gpa.free(parent);
            };
        }
        self.cursor = 0;
    }

    /// True when the listed directory has somewhere to go up to.
    fn canGoUp(path: []const u8) bool {
        if (path.len == 0) return true;
        const parent = parentOf(path);
        return !std.mem.eql(u8, parent, path);
    }

    /// The absolute-or-relative path a row refers to: the listed directory joined to the row's name.
    pub fn fullPath(self: *const Picker, gpa: std.mem.Allocator, entry: Candidate) ![]u8 {
        const base = self.dir();
        if (base.len == 0) return gpa.dupe(u8, entry.name);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, entry.name });
    }

    /// Move the cursor, clamping at both ends so the listing cannot be walked off either edge.
    pub fn moveCursor(self: *Picker, delta: isize) void {
        if (self.entries.items.len == 0) return;
        const last: isize = @intCast(self.entries.items.len - 1);
        var next: isize = @intCast(self.cursor);
        next += delta;
        if (next < 0) next = 0;
        if (next > last) next = last;
        self.cursor = @intCast(next);
    }

    /// True when `path` names a directory, so the caller knows to enter it rather than try to open it as a database.
    pub fn isDirectory(io: Io, path: []const u8) bool {
        const parent = parentOf(path);
        const base = baseOf(path);
        const handle = std.Io.Dir.cwd().openDir(io, parent, .{}) catch return false;
        defer handle.close(io);
        const st = handle.statFile(io, base, .{}) catch return false;
        return st.kind == .directory;
    }
};

/// The last path component, or "" when there is none.
pub fn baseOf(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return "/";
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[slash + 1 ..];
}

/// The directory containing `path`; "." when it has no separator.
pub fn parentOf(path: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, path, "/");
    if (trimmed.len == 0) return "/";
    const slash = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return ".";
    if (slash == 0) return "/";
    return trimmed[0..slash];
}

// Tests

const testing = std.testing;

test "the extension list is matched case-insensitively" {
    try testing.expect(looksLikeDatabase("app.db"));
    try testing.expect(looksLikeDatabase("app.DB"));
    try testing.expect(looksLikeDatabase("data.sqlite3"));
    try testing.expect(looksLikeDatabase("x.db3"));
    try testing.expect(looksLikeDatabase("a.b.sqlite"));
    // Not a database, or not a whole-extension match.
    try testing.expect(!looksLikeDatabase("notes.txt"));
    try testing.expect(!looksLikeDatabase("db"));
    try testing.expect(!looksLikeDatabase("app.db.txt"));
    try testing.expect(!looksLikeDatabase(""));
}

test "the field is bound to the picker's own storage" {
    // The regression the in-place `init` exists to prevent: a Picker returned by value would carry a field slice pointing into the local it was copied from.
    var p: Picker = undefined;
    p.init();
    p.field.setText("some.db");

    try testing.expectEqual(
        @intFromPtr(&p.field_buf),
        @intFromPtr(p.field.editor.buf.ptr),
    );
    try testing.expectEqual(@as(usize, p.field_buf.len), p.field.editor.buf.len);
    try testing.expectEqualStrings("some.db", p.field.text());
}

test "setDir truncates rather than overflowing" {
    var p: Picker = undefined;
    p.init();
    p.setDir("/a/very/long/path");
    try testing.expectEqualStrings("/a/very/long/path", p.dir());

    const huge = "/" ++ "x" ** (path_capacity * 2);
    p.setDir(huge);
    try testing.expectEqual(@as(usize, path_capacity), p.dir().len);
}

test "the cursor clamps at both ends" {
    var p: Picker = undefined;
    p.init();
    defer p.deinit(testing.allocator);

    // No entries: the cursor stays put rather than going out of range.
    p.moveCursor(1);
    p.moveCursor(-1);
    try testing.expectEqual(@as(usize, 0), p.cursor);

    const three = [_]Seed{
        .{ .name = "a", .is_dir = false },
        .{ .name = "b", .is_dir = false },
        .{ .name = "c", .is_dir = false },
    };
    try addEntries(testing.allocator, &p, &three);

    p.moveCursor(-1);
    try testing.expectEqual(@as(usize, 0), p.cursor);
    p.moveCursor(1);
    p.moveCursor(1);
    try testing.expectEqual(@as(usize, 2), p.cursor);
    p.moveCursor(1); // past the end
    try testing.expectEqual(@as(usize, 2), p.cursor);
}

test "directories sort before files, each group by name" {
    var p: Picker = undefined;
    p.init();
    defer p.deinit(testing.allocator);

    const mixed = [_]Seed{
        .{ .name = "z.db", .is_dir = false },
        .{ .name = "sub", .is_dir = true },
        .{ .name = "a.db", .is_dir = false },
        .{ .name = "abc", .is_dir = true },
    };
    try addEntries(testing.allocator, &p, &mixed);
    std.sort.pdq(Candidate, p.entries.items, {}, Picker.lessThan);

    try testing.expectEqualStrings("abc", p.entries.items[0].name);
    try testing.expectEqualStrings("sub", p.entries.items[1].name);
    try testing.expectEqualStrings("a.db", p.entries.items[2].name);
    try testing.expectEqualStrings("z.db", p.entries.items[3].name);
}

test "path helpers split a path the way a shell would" {
    try testing.expectEqualStrings("app.db", baseOf("/tmp/app.db"));
    try testing.expectEqualStrings("/tmp", parentOf("/tmp/app.db"));
    try testing.expectEqualStrings("app.db", baseOf("app.db"));
    try testing.expectEqualStrings(".", parentOf("app.db"));
    // A trailing slash is a separator, not part of a name: the last component of "/a/b/" is "b", and its parent is "/a".
    try testing.expectEqualStrings("b", baseOf("/a/b/"));
    try testing.expectEqualStrings("/a", parentOf("/a/b/"));
    // A root path has no parent to go up to.
    try testing.expectEqualStrings("/", baseOf("/"));
    try testing.expectEqualStrings("/", parentOf("/"));
    try testing.expectEqualStrings("", baseOf(""));
}

test "fullPath joins the directory onto the entry name" {
    const gpa = testing.allocator;
    var p: Picker = undefined;
    p.init();
    defer p.deinit(gpa);

    p.setDir("/tmp/data");
    const joined = try p.fullPath(gpa, .{ .name = "app.db", .is_dir = false });
    defer gpa.free(joined);
    try testing.expectEqualStrings("/tmp/data/app.db", joined);

    // With no directory set, the bare name is the best that can be offered — and must not come out as "/app.db".
    p.setDir("");
    const bare = try p.fullPath(gpa, .{ .name = "app.db", .is_dir = false });
    defer gpa.free(bare);
    try testing.expectEqualStrings("app.db", bare);
}

test "isDirectory tells a directory from a file" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scratch = try ScratchDir.init(gpa, io, "meja-picker-isdir");
    defer scratch.deinit();

    try scratch.write(io, "real.db", "");
    try scratch.makeDir(io, "sub");

    const sub_path = try scratch.join(gpa, "sub");
    defer gpa.free(sub_path);
    const file_path = try scratch.join(gpa, "real.db");
    defer gpa.free(file_path);

    try testing.expect(Picker.isDirectory(io, sub_path));
    try testing.expect(!Picker.isDirectory(io, file_path));
    // Unstattable means "not a directory", so the caller tries to open it and the failure names the path.
    try testing.expect(!Picker.isDirectory(io, "/no/such/file/at/all.db"));
}

test "scanning a real directory finds its databases and its subdirectories" {
    // The picker is only useful if it lists what is actually there, so this scans a directory the test itself populated.
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scratch = try ScratchDir.init(gpa, io, "meja-picker-scan");
    defer scratch.deinit();

    try scratch.makeDir(io, "sub");
    try scratch.write(io, "one.db", "");
    try scratch.write(io, "two.sqlite3", "");
    try scratch.write(io, "notes.txt", "");

    var p: Picker = undefined;
    p.init();
    defer p.deinit(gpa);

    p.setDir(scratch.path);
    p.scan(gpa, io);

    try testing.expect(p.error_message == null);
    // ".." first, then the directory, then the two databases.
    try testing.expectEqual(@as(usize, 4), p.entries.items.len);
    try testing.expectEqualStrings("..", p.entries.items[0].name);
    try testing.expect(p.entries.items[0].is_dir);
    try testing.expectEqualStrings("sub", p.entries.items[1].name);
    try testing.expect(p.entries.items[1].is_dir);
    try testing.expectEqualStrings("one.db", p.entries.items[2].name);
    try testing.expect(!p.entries.items[2].is_dir);
    try testing.expectEqualStrings("two.sqlite3", p.entries.items[3].name);

    for (p.entries.items) |e| {
        if (e.is_dir) continue;
        try testing.expect(looksLikeDatabase(e.name));
    }
}

test "a listing with nothing in it is empty, not an error" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scratch = try ScratchDir.init(gpa, io, "meja-picker-empty");
    defer scratch.deinit();
    try scratch.write(io, "notes.txt", "");

    var p: Picker = undefined;
    p.init();
    defer p.deinit(gpa);
    p.setDir(scratch.path);
    p.scan(gpa, io);

    try testing.expect(p.error_message == null);
    // Only ".." — the one file is not offered.
    try testing.expectEqual(@as(usize, 1), p.entries.items.len);
    try testing.expectEqualStrings("..", p.entries.items[0].name);
}

test "an unreadable directory reports why instead of listing nothing" {
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();

    var p: Picker = undefined;
    p.init();
    defer p.deinit(gpa);

    p.setDir("/no/such/directory/anywhere");
    p.scan(gpa, threaded.io());

    try testing.expect(p.error_message != null);
    try testing.expectEqual(@as(usize, 0), p.entries.items.len);
}

test "rescanning does not leak the previous listing" {
    // `scan` frees the old entries first; without that, every Ctrl+O would strand a copy of every name it listed.
    const gpa = testing.allocator;
    var threaded: Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scratch = try ScratchDir.init(gpa, io, "meja-picker-rescan");
    defer scratch.deinit();
    try scratch.write(io, "a.db", "");

    var p: Picker = undefined;
    p.init();
    defer p.deinit(gpa);

    p.setDir(scratch.path);
    p.scan(gpa, io);
    const first = p.entries.items.len;
    try testing.expect(first > 0);

    p.scan(gpa, io);
    try testing.expectEqual(first, p.entries.items.len);
    // The cursor is reset by a rescan, so it is always a valid index.
    try testing.expectEqual(@as(usize, 0), p.cursor);
}

// Test helpers

const Seed = struct { name: []const u8, is_dir: bool };

/// Append entries, owning the names so `Picker.deinit` can free them.
fn addEntries(
    gpa: std.mem.Allocator,
    p: *Picker,
    seeds: []const Seed,
) !void {
    for (seeds) |seed| {
        try p.entries.append(gpa, .{
            .name = try gpa.dupe(u8, seed.name),
            .is_dir = seed.is_dir,
        });
    }
}

/// A directory under the build cache that the test owns outright.
const ScratchDir = struct {
    gpa: std.mem.Allocator,
    io: Io,
    path: []const u8,

    fn init(gpa: std.mem.Allocator, io: Io, name: []const u8) !ScratchDir {
        const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}", .{name});
        errdefer gpa.free(path);
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
        try std.Io.Dir.cwd().createDirPath(io, path);
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    fn deinit(self: *ScratchDir) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.path) catch {};
        self.gpa.free(self.path);
    }

    fn write(self: *const ScratchDir, io: Io, name: []const u8, data: []const u8) !void {
        const handle = try std.Io.Dir.cwd().openDir(io, self.path, .{ .access_sub_paths = true });
        defer handle.close(io);
        try handle.writeFile(io, .{ .sub_path = name, .data = data });
    }

    fn makeDir(self: *const ScratchDir, io: Io, name: []const u8) !void {
        const handle = try std.Io.Dir.cwd().openDir(io, self.path, .{ .access_sub_paths = true });
        defer handle.close(io);
        try handle.createDirPath(io, name);
    }

    /// Caller owns the result.
    fn join(self: *const ScratchDir, gpa: std.mem.Allocator, name: []const u8) ![]u8 {
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ self.path, name });
    }
};
