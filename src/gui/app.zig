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
const theme = @import("theme.zig");

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
    status: []const u8 = "no database open",

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
    ed_has_focus: bool = true,

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
            self.status = "out of memory";
            return;
        };
        defer self.gpa.free(zpath);

        self.db.init(self.io, zpath) catch |err| {
            self.open_error = err;
            self.status = "cannot open database";
            return;
        };
        self.db_open = true;
        self.open_error = null;
        self.db_path = path;
        self.loadTables();
        self.status = "ready";
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
            self.status = "no database open";
            return;
        }
        const text = self.ed.text();
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            self.status = "nothing to run";
            return;
        }

        const statements = sql.splitStatements(self.gpa, text) catch {
            self.status = "out of memory";
            return;
        };
        defer sql.freeStatements(self.gpa, statements);

        // Only the LAST statement's result is shown, which matches what
        // the sqlite3 CLI does: a script's final SELECT is the answer.
        for (statements) |st| {
            self.clearResult();
            self.result = query.run(self.gpa, &self.db, st.text, .{}) catch {
                self.status = "query failed";
                continue;
            };
            self.has_result = true;
            if (self.result.error_message) |m| {
                self.status = m;
            } else if (self.result.columnCount() == 0) {
                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{d} rows affected", .{
                    self.result.rows_affected,
                }) catch "ok";
                self.status = self.gpa.dupe(u8, msg) catch "ok";
            } else {
                self.status = "ok";
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

    pub fn onKey(self: *App, mods: input_mod.Mods, keycode: u32) bool {
        if (!self.ed_has_focus) return false;
        switch (editor.handleKey(&self.ed, keycode, mods.shift, mods.ctrl)) {
            .run_requested => {
                self.runEditor();
                return true;
            },
            .edited => return true,
            .ignored => return false,
        }
    }
};
