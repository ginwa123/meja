//! Application state for the GUI: what is open, what the editor holds,
//! and what the last query returned.
//!
//! Split out from `main.zig` so it carries NO drawing code at all. That
//! separation is what makes the end-to-end test possible: a test can
//! drive the real `App` — type a query, press Ctrl+Enter, read the
//! result — and only `main.zig` knows how to put it on screen.
//!
//! Nothing here imports glinlandui except for the two key-modifier
//! types, which are plain structs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const database = @import("databases").database;
const query = @import("meja").query;
const schema = @import("meja").schema;
const sql = @import("meja").sql;
const value_mod = @import("meja").value;
const glin = @import("glinlandui");
const input_mod = glin.components.input;

const editor = @import("editor.zig");
const grid = @import("grid.zig");
const picker_mod = @import("picker.zig");
const dialog = @import("dialog.zig");
const theme = @import("theme.zig");

/// Which text field owns the keyboard.
///
/// The window has two editable fields — the SQL editor and the picker's
/// path — and a key event goes to exactly one of them, so which is
/// which is stated rather than inferred from which panel happens to be
/// open.
pub const Focus = enum { sql_editor, path };

/// One table in the sidebar, with its columns loaded lazily.
const TableNode = struct {
    name: []const u8,
    kind: schema.ObjectKind,
    expanded: bool = false,
    columns: ?[]schema.Column = null,
    /// True once loading columns failed, so the tree shows an error
    /// rather than retrying every frame.
    columns_failed: bool = false,
};

pub const App = struct {
    /// Allocator used for schema and result storage.
    gpa: Allocator,
    io: Io,

    db: database.Db = .{},
    db_open: bool = false,

    /// The open database's path, and the storage behind it.
    ///
    /// It is OWNED rather than borrowed, which it has to be: the path
    /// now comes from the picker's field, and that field is editable,
    /// so a slice of it would change under the UI the moment the user
    /// typed. `db_path` is always a slice of `db_path_buf`, or empty.
    db_path_buf: [picker_mod.path_capacity]u8 = undefined,
    db_path_len: usize = 0,
    db_path: []const u8 = "",
    /// Set when the open failed, so the UI can explain why.
    open_error: ?anyerror = null,

    // Schema tree.
    tables: std.ArrayList(TableNode) = .empty,
    /// Index into `tables` of the selected table, if any.
    selected: ?usize = null,

    // Result set.
    result: query.ResultSet = undefined,
    has_result: bool = false,

    /// The status line, and the storage behind it.
    ///
    /// Owned for the same reason `db_path` is: it is handed to a draw
    /// command that keeps the pointer until the frame is rasterised, and
    /// it used to be built by `dupe`-ing onto the heap with nothing
    /// ever freeing it. `status` is always a slice of `status_buf`.
    status_buf: [256]u8 = undefined,
    status: []const u8 = "",

    // Column pixel widths, recomputed when a result arrives.
    col_widths: std.ArrayList(u16) = .empty,

    // Editor.
    sql_buf: [16 * 1024]u8 = undefined,

    /// Scratch space for every string handed to a draw command in one
    /// frame.
    ///
    /// This exists because the draw calls are IMMEDIATE MODE: a
    /// `text.label` call stores the pointer it is given and the
    /// rasteriser reads it later in the same frame, after the function
    /// that produced it has already returned. A label fed a pointer
    /// into a stack buffer therefore points at dead memory by the time
    /// anything looks at it -- the text silently renders empty.
    ///
    /// So every label's text is written here instead, and the arena is
    /// reset once per frame. That makes the text live exactly as long as
    /// the frame that needs it, with no allocation.
    text_arena: [512 * 1024]u8 = undefined,
    text_used: usize = 0,
    ed: editor.Editor = undefined,

    // Database selection.
    picker: picker_mod.Picker = undefined,
    focus: Focus = .sql_editor,

    // Cached layout metrics, refreshed each frame.
    window_w: u32 = 0,
    window_h: u32 = 0,

    /// Reset the text arena. Called once at the start of each frame,
    /// before anything claims space.
    pub fn beginFrame(self: *App) void {
        self.text_used = 0;
    }

    /// Claim `n` bytes of frame-scoped scratch.
    ///
    /// Returns a zero-length slice rather than failing when the arena is
    /// exhausted: a cell that runs out of room draws blank, which is a
    /// cosmetic problem, whereas panicking mid-frame would take down the
    /// window. A `ResultSet` wider than ~500 columns would hit this.
    pub fn claimText(self: *App, n: usize) []u8 {
        if (self.text_used + n > self.text_arena.len) return &[_]u8{};
        const start = self.text_used;
        self.text_used += n;
        return self.text_arena[start..self.text_used];
    }

    /// Initialise IN PLACE.
    ///
    /// This deliberately does not return an `App` by value. The editor
    /// holds a slice of `sql_buf`, a field of this very struct, so
    /// returning a copy would leave `ed.buf` pointing into the local
    /// that was copied FROM -- dead memory the moment the function
    /// returned. The first keystroke would then write into freed stack,
    /// which is exactly the crash this signature exists to prevent.
    ///
    /// `App.init(allocator, io)` looked correct and compiled; nothing
    /// about the type system flagged it.
    pub fn init(self: *App, gpa: Allocator, io: Io) void {
        self.* = .{ .gpa = gpa, .io = io };
        // Bound to `sql_buf` AFTER the struct is in its final place, so
        // the pointer refers to the App the caller actually holds.
        self.ed = editor.Editor.init(&self.sql_buf);
        // Same rule for the picker's own field buffer.
        self.picker.init();
        self.setStatus("no database open — Ctrl+O to choose one", .{});
    }

    /// Write the status line.
    ///
    /// Truncates rather than failing: a status line that is a character
    /// short of a full error is still useful, and a UI thread must not
    /// unwind out of a key handler. `status` always points into
    /// `status_buf`, so it outlives the call that produced it and never
    /// has to be freed.
    pub fn setStatus(self: *App, comptime fmt: []const u8, args: anytype) void {
        self.status = std.fmt.bufPrint(self.status_buf[0..], fmt, args) catch
            self.status_buf[0..0];
    }

    /// Open a database and load the schema. Safe to call twice.
    pub fn open(self: *App, path: []const u8) void {
        if (self.db_open) {
            self.db.deinit();
            self.db_open = false;
        }
        self.freeTables();
        self.clearResult();

        // `init` takes a NUL-terminated path because it is handed to
        // sqlite3_open; a slice from argv is not sentinel-terminated.
        const zpath = self.gpa.dupeZ(u8, path) catch {
            self.setStatus("out of memory", .{});
            return;
        };
        defer self.gpa.free(zpath);

        self.db.init(self.io, zpath) catch |err| {
            self.open_error = err;
            // Say WHICH path failed, not just that something did. The
            // path is the only thing the user can act on.
            self.setStatus("cannot open {s}: {s}", .{ path, @errorName(err) });
            // Leave the previous path alone: it is still what the
            // window is showing, and clearing it would make a failed
            // switch look like a closed database.
            return;
        };
        self.db_open = true;
        self.open_error = null;
        self.setDbPath(path);
        self.loadTables();
        self.setStatus("ready — {s}", .{self.db_path});
    }

    /// Copy the open database's path into storage the App owns.
    ///
    /// The copy is the point: the caller's slice may be argv, the
    /// picker's field, or a scratch buffer, and only this one is
    /// guaranteed to still hold the same bytes when the UI reads it.
    fn setDbPath(self: *App, path: []const u8) void {
        const n = @min(path.len, self.db_path_buf.len);
        // Overlap-tolerant, in case a caller passes `self.db_path` back in.
        @memmove(self.db_path_buf[0..n], path[0..n]);
        self.db_path_len = n;
        self.db_path = self.db_path_buf[0..n];
    }

    // --- database selection ------------------------------------------------
    //
    // The one thing a database browser must let a user do is point it
    // at a different database. Until the picker existed the only way to
    // change it was to restart the process with a different argument,
    // which is not a way to browse.

    /// Show the picker and put the keyboard in the path field.
    ///
    /// Reopening starts from what is already open rather than from the
    /// process directory, so the user is not dropped somewhere new every
    /// time they look.
    pub fn openPicker(self: *App) void {
        self.picker.open = true;
        self.focus = .path;

        // The field starts EMPTY, deliberately. Seeding it with the open
        // database's path means the first character the user types is
        // APPENDED to it, so typing `/data/app.db` into a field that
        // already said `:memory:` silently produced
        // `:memory:/data/app.db` and a baffling "cannot open". An empty
        // field has no wrong answer.
        self.picker.field.clear();

        // The listing, by contrast, starts where the user already is: the
        // directory holding the open database. That is the one piece of
        // context worth carrying over.
        if (self.picker.dir_len == 0 and self.db_open and self.db_path.len > 0) {
            const parent = picker_mod.parentOf(self.db_path);
            if (picker_mod.Picker.isDirectory(self.io, parent)) self.picker.setDir(parent);
        }
        self.picker.scan(self.gpa, self.io);
        self.setStatus(
            "Enter opens the path — Up/Down choose, Tab goes to SQL, Ctrl+O closes",
            .{},
        );
    }

    /// Ask the SYSTEM file dialog for a database, and open what it returns.
    ///
    /// The other way to point the app at a database, next to `openPicker`'s
    /// hand-rolled one. Which is primary depends on the host: on a desktop
    /// this is the button people reach for, because it is the dialog their
    /// operating system already taught them; the picker is what still works
    /// when there is no system dialog at all, and what the GUI tests drive,
    /// because a test cannot click a native dialog.
    ///
    /// It blocks while the dialog is open. That is what a file dialog IS —
    /// AppKit, COM and the XDG portal all run their own modal loop — and the
    /// window is frozen for the duration by design, not by accident. The one
    /// consequence here is that this cannot be called from anywhere that
    /// expects the app to keep repainting.
    pub fn browseForDatabase(self: *App) void {
        // Start where the user already is: the directory of the open
        // database, or the picker's if it has one. Null when there is
        // nowhere obvious — `:memory:` has no parent directory, and
        // "the current directory" of a GUI process is whatever the user
        // launched it from, which is rarely where their data is. The
        // platform's own default (a home directory) is the better guess
        // when we have none.
        const start: ?[]const u8 = blk: {
            if (self.picker.dir_len > 0) break :blk self.picker.dir();
            if (self.db_open and self.db_path.len > 0 and
                !std.mem.eql(u8, self.db_path, ":memory:"))
            {
                break :blk picker_mod.parentOf(self.db_path);
            }
            break :blk null;
        };

        // `browse` is fallible only because the toolkit's is, and on this
        // target it is always `Unsupported` — which is the case the GUI tests
        // exercise and the one a browser hits.
        const outcome = dialog.browse(self.gpa, start) catch
            dialog.Outcome{ .unavailable = .failed };
        // The path is a COPY the outcome owns, so it is released here. It is
        // copied again by `usePath` into storage the App owns, which is what
        // makes it safe to free at the end of this scope.
        defer outcome.free(self.gpa);

        switch (outcome) {
            .opened => |path| {
                if (path.len == 0) {
                    self.setStatus("the file dialog returned an empty path", .{});
                    return;
                }
                // Through `usePath`, like every other route to a database,
                // so "what Browse opens" and "what a clicked row opens"
                // cannot drift apart.
                self.usePath(path);
            },
            .cancelled => {
                // The user closed the window on purpose. Say so briefly and
                // change nothing: the previously open database is still open,
                // and clearing it would make a cancel look like a close.
                self.setStatus("browse cancelled — still on {s}", .{if (self.db_open) self.db_path else "nothing"});
            },
            .unavailable => |limit| {
                self.setStatus("{s}", .{limit.explain()});
            },
        }
    }

    pub fn closePicker(self: *App) void {
        self.picker.open = false;
        self.focus = .sql_editor;
        if (self.db_open) self.setStatus("ready — {s}", .{self.db_path});
    }

    /// List `path` as the picker's directory.
    pub fn enterDirectory(self: *App, path: []const u8) void {
        self.picker.setDir(path);
        self.picker.scan(self.gpa, self.io);
        if (self.picker.error_message) |err| {
            self.setStatus("cannot read {s}: {s}", .{ self.picker.dir(), err });
        } else {
            self.setStatus("{d} entries in {s}", .{
                self.picker.entries.items.len,
                self.picker.dir(),
            });
        }
    }

    /// Go up one level, unless already at a root.
    pub fn goUp(self: *App) void {
        const here = self.picker.dir();
        const parent = picker_mod.parentOf(here);
        if (parent.len == 0 or std.mem.eql(u8, parent, here)) {
            self.setStatus("already at the top", .{});
            return;
        }
        self.enterDirectory(parent);
    }

    /// Act on a clicked listing row: a directory is entered, a file
    /// opened. The keyboard's Up/Down + Enter land here too, so the two
    /// input methods cannot disagree.
    pub fn activateCandidate(self: *App, index: usize) void {
        const p = &self.picker;
        if (index >= p.entries.items.len) return;
        p.cursor = index;
        const entry = p.entries.items[index];

        // ".." is a navigation row, not a real one: joining it onto the
        // directory would produce a path that does not name anything.
        if (std.mem.eql(u8, entry.name, "..")) {
            self.goUp();
            return;
        }
        const full = p.fullPath(self.gpa, entry) catch {
            self.setStatus("out of memory", .{});
            return;
        };
        defer self.gpa.free(full);
        self.usePath(full);
    }

    /// Open, or — for a directory — enter, whatever is in the path
    /// field. Trimmed first because a trailing newline is what a field
    /// collects from a paste.
    pub fn openTypedPath(self: *App) void {
        const typed = std.mem.trim(u8, self.picker.field.text(), " \t\r\n");
        if (typed.len == 0) {
            self.setStatus("type a path, or choose one below", .{});
            return;
        }
        self.usePath(typed);
    }

    /// The one place a path becomes the open database, or the listed
    /// directory. Both the typed field and a clicked row come through
    /// here, so "what Enter does" and "what clicking does" cannot drift
    /// apart.
    pub fn usePath(self: *App, path: []const u8) void {
        // A directory cannot be opened as a database, and reporting that
        // as an error would be a lie: it is navigation, so it navigates.
        if (picker_mod.Picker.isDirectory(self.io, path)) {
            self.picker.field.setText(path);
            self.enterDirectory(path);
            return;
        }

        self.open(path);
        if (!self.db_open) return; // `open` already said what went wrong.

        self.picker.field.setText(self.db_path);
        // Follow the database into its own directory, so reopening the
        // panel starts where the user now is.
        self.enterDirectory(picker_mod.parentOf(self.db_path));
        self.closePicker();
    }

    pub fn freeTables(self: *App) void {
        for (self.tables.items) |*t| {
            if (t.columns) |cols| {
                schema.freeColumns(self.gpa, cols);
                t.columns = null;
            }
            self.gpa.free(t.name);
        }
        self.tables.deinit(self.gpa);
        self.tables = .empty;
    }

    pub fn clearResult(self: *App) void {
        if (self.has_result) {
            self.result.deinit();
            self.has_result = false;
        }
        self.col_widths.deinit(self.gpa);
        self.col_widths = .empty;
    }

    pub fn loadTables(self: *App) void {
        if (!self.db_open) return;
        const objects = schema.listObjects(self.gpa, &self.db, &.{ .table, .view }) catch {
            self.status = "cannot read schema";
            return;
        };
        defer schema.freeObjects(self.gpa, objects);

        for (objects) |o| {
            self.tables.append(self.gpa, .{
                .name = self.gpa.dupe(u8, o.name) catch return,
                .kind = o.kind,
            }) catch return;
        }
    }

    /// Run whatever is in the editor. The core splits multi-statement
    /// scripts, so a script with three statements runs all three.
    pub fn runEditor(self: *App) void {
        if (!self.db_open) {
            self.setStatus("no database open — Ctrl+O to choose one", .{});
            return;
        }
        const text = self.ed.text();
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            self.setStatus("nothing to run", .{});
            return;
        }

        const statements = sql.splitStatements(self.gpa, text) catch {
            self.setStatus("out of memory", .{});
            return;
        };
        defer sql.freeStatements(self.gpa, statements);

        // Only the LAST statement's result is shown, which matches what
        // the sqlite3 CLI does: a script's final SELECT is the answer.
        for (statements) |st| {
            self.clearResult();
            self.result = query.run(self.gpa, &self.db, st.text, .{}) catch {
                self.setStatus("query failed", .{});
                continue;
            };
            self.has_result = true;
            if (self.result.error_message) |m| {
                // COPIED, not borrowed. The result set is deinited on the
                // next run and on every database switch, so a status
                // line pointing into it would outlive the memory it
                // names.
                self.setStatus("{s}", .{m});
            } else if (self.result.columnCount() == 0) {
                self.setStatus("{d} rows affected", .{self.result.rows_affected});
            } else {
                self.setStatus("ok", .{});
            }
            self.recomputeColumnWidths();
        }
    }

    /// Size each column to its widest cell. Only the rows actually
    /// loaded are measured, which is the same set the grid draws.
    pub fn recomputeColumnWidths(self: *App) void {
        self.col_widths.deinit(self.gpa);
        self.col_widths = .empty;
        if (!self.has_result) return;

        const width = self.result.columnCount();
        for (0..width) |c| {
            // Measure a bounded sample: measuring 200k rows to size a
            // column is exactly the kind of work that makes a browser
            // feel broken, and the width barely changes past a few dozen.
            var samples: std.ArrayList([]const u8) = .empty;
            defer {
                for (samples.items) |s| self.gpa.free(s);
                samples.deinit(self.gpa);
            }

            var sampled: usize = 0;
            for (self.result.rows) |row| {
                if (sampled >= 100) break;
                if (c >= row.values.len) continue;
                const v = row.values[c];
                if (v.isNull()) continue; // renders as the word "NULL"
                var cell_buf: [256]u8 = undefined;
                const rendered = value_mod.render(&cell_buf, v);
                samples.append(self.gpa, self.gpa.dupe(u8, rendered) catch break) catch break;
                sampled += 1;
            }

            const header = if (c < self.result.columns.len) self.result.columns[c].name else "";
            const w = grid.columnWidth(samples.items, header, theme.font_size, theme.cell_padding);
            self.col_widths.append(self.gpa, w) catch return;
        }
    }

    /// Toggle a table's expansion, loading its columns on first open.
    pub fn toggleTable(self: *App, index: usize) void {
        if (index >= self.tables.items.len) return;
        const t = &self.tables.items[index];
        t.expanded = !t.expanded;
        if (t.expanded and t.columns == null and !t.columns_failed) {
            const cols = schema.listColumns(self.gpa, &self.db, t.name) catch {
                t.columns_failed = true;
                return;
            };
            t.columns = cols;
        }
    }

    /// Load a table's first page into the grid and load it into the editor.
    pub fn browseTable(self: *App, index: usize) void {
        if (index >= self.tables.items.len) return;
        self.selected = index;
        const t = &self.tables.items[index];

        // The editor gets a plain `SELECT *`, which is the query a user
        // would have written, so they can edit it into something else.
        const quoted = sql.quoteIfNeeded(self.gpa, t.name) catch return;
        defer self.gpa.free(quoted);
        const seed = std.fmt.allocPrint(self.gpa, "SELECT * FROM {s}", .{quoted}) catch return;
        defer self.gpa.free(seed);
        self.ed.setText(seed);

        self.runEditor();
    }

    /// Route one key event.
    ///
    /// Ctrl+O is the only global shortcut — it opens the picker and puts
    /// the keyboard in the path field, and closes it again. Everything
    /// else goes to whichever field `focus` names, because the window
    /// has two of them and a keystroke may only have one meaning.
    pub fn onKey(self: *App, mods: input_mod.Mods, keycode: u32) bool {
        if (mods.ctrl and keycode == editor.KEY_O) {
            if (self.picker.open) self.closePicker() else self.openPicker();
            return true;
        }
        if (self.focus == .path) return self.onPathKey(mods, keycode);
        // The picker is open but the editor has the keyboard: Tab is how
        // the user gets to the path field without reaching for the mouse.
        if (self.picker.open and keycode == editor.KEY_TAB) {
            self.focus = .path;
            return true;
        }
        return self.onEditorKey(mods, keycode);
    }

    fn onEditorKey(self: *App, mods: input_mod.Mods, keycode: u32) bool {
        switch (editor.handleKey(&self.ed, keycode, mods.shift, mods.ctrl)) {
            .run_requested => {
                self.runEditor();
                return true;
            },
            .edited => return true,
            .ignored => return false,
        }
    }

    /// Keys for the picker's path field.
    ///
    /// Enter and the arrow keys are taken BEFORE the shared editor
    /// handler, because the sensible meanings here are not the editor's:
    /// a path has no lines to break, and Up/Down through a listing is
    /// more use than moving a caret through a single-line string.
    fn onPathKey(self: *App, mods: input_mod.Mods, keycode: u32) bool {
        switch (keycode) {
            editor.KEY_ENTER => {
                self.openTypedPath();
                return true;
            },
            editor.KEY_TAB => {
                self.focus = .sql_editor;
                return true;
            },
            editor.KEY_UP => {
                self.picker.moveCursor(-1);
                return true;
            },
            editor.KEY_DOWN => {
                self.picker.moveCursor(1);
                return true;
            },
            else => {},
        }
        // Everything else — typing, Backspace, Home/End, selection — is
        // exactly what the SQL editor does, so it is literally the same
        // handler and the same editor type.
        return switch (editor.handleKey(&self.picker.field, keycode, mods.shift, mods.ctrl)) {
            .run_requested, .edited => true,
            .ignored => false,
        };
    }
};
