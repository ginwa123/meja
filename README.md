# meja

A cross-platform database browser for SQLite, written in pure Zig.

```
meja app.db                     # interactive session
meja app.db -c "SELECT * FROM users LIMIT 10"
meja app.db -t                  # list tables
meja app.db -d users            # describe a table
meja app.db -s                  # print the schema
sqlite3 dump.sql | meja app.db --stdin
```

## What it is

Two frontends over one shared core:

- **`meja`** — the CLI. No display server, so it builds and tests on
  Linux, macOS and Windows without a GUI session.
- **`meja-gui`** — a glinlandui window: schema tree, virtualised data
  grid, and a multi-line SQL editor (optional; `-Dgui=false` drops it).

Both depend on `meja.core`, which contains all the data-access logic.
Neither frontend has any of its own.

## Why the core looks the way it does

The `databases` binding underneath is thin — deliberately, but thin
enough that a database *client* has to supply three things it does not
expose. Each has a module, and each is documented at the point of use:

1. **Only the first statement of a multi-statement string runs.**
   `sqlite3_prepare_v2` is called with a NULL tail pointer, so the rest
   is silently discarded. `core/sql.zig` splits scripts itself, with a
   scanner that respects strings, quoted identifiers, both comment
   styles, and `CREATE TRIGGER ... BEGIN ... END` bodies.

2. **Rows carry no column names.** `sqlite3_column_name` is never
   called, so a row is a bare `[][]u8`. `core/select_list.zig` recovers
   names from the SQL text: bare references name themselves, `AS` and
   bare aliases win, and anything else keeps its expression text — what
   SQLite's own CLI does. It is explicitly a heuristic on text, not a
   grammar parser, and it never invents a name. `SELECT *` is expanded
   against `PRAGMA table_info` rather than guessed.

3. **Everything is text, and NULL is the empty string.** `core/value.zig`
   pairs each value with its storage class, and `core/query.zig` gets
   that class by rewriting the query it controls to interleave
   `typeof(col)` before every column. So `NULL` and `''` are finally
   distinguishable, and `1` the integer is not confused with `'1'` the
   text.

The query engine also pages (`LIMIT`/`OFFSET`, with an honest
`truncated` flag), times each statement, and never appends a `LIMIT` to
a query that already has one — a second `LIMIT` changes what the SQL
means.

## Safety

Table and column names cannot be bound as parameters (`PRAGMA` will not
take a placeholder for a table name), so every such interpolation goes
through `sql.quoteIfNeeded`, and a test feeds it a name containing a
quote and a semicolon to prove it stays one identifier. Values *are*
bound, and internal objects are filtered with `GLOB` rather than `LIKE`
— `_` is `LIKE`'s single-character wildcard, so `LIKE 'sqlite_%'` would
also match a user's table named `sqliteXyz`.

Note that `;` is a genuine statement separator: `meja db -c "SELECT 1;
DROP TABLE t"` really does run both statements, exactly as `sqlite3`
does. That is a script, not an injection.

## Building

Both dependencies are local path deps, relative in `build.zig.zon`
(Zig 0.16 rejects absolute paths there):

| dep | what it provides |
|---|---|
| `../ruangsql` (`databases`) | sqlite3 + libpq bindings |
| `../glinlandui` | cross-platform GUI toolkit, including the system file dialog |

```sh
zig build                    # both binaries
zig build test               # 254 core + CLI tests
zig build test -Dgui=false   # CLI only, no Wayland toolchain needed
zig build test-gui           # GUI tests only (headless, no display)
zig build run -- app.db      # run the CLI
zig build run-gui -- app.db  # run the GUI
zig build inspect -- app.db  # render one frame and print it
```

`meja-gui` needs a **Wayland compositor**; it reports
`error.NoWaylandDisplay` rather than starting without one. The GUI
tests do not, because glinlandui's test build selects a portable
backend.

`zig build inspect` opens a real database, runs a real frame through the
headless driver and prints what it drew. It is the quickest way to see
what the GUI is doing without a screen:

```
$ zig build inspect -- app.db
TABLES (1):
  users
EDITOR: SELECT * FROM users
RESULT: 3 rows x 4 cols in 9 us
COLUMNS: id name email score
| 1  | alice | a@x.com | 91.5 |
| 2  | bob   | b@x.com | 72   |
| 3  | carol | NULL    | NULL |
```

`meja-gui app.db` opens the database; with no argument it starts on an
in-memory one. In the window: click a table to browse it, type SQL and
press **Ctrl+Enter** to run, **Ctrl+K** to delete the current line.

## Opening a database

Two ways, and both are always there:

- **Browse…** opens the **system** file dialog — the XDG desktop portal
  on Linux, `NSOpenPanel` on macOS, `IFileDialog` on Windows, through
  glinlandui's `file_dialog`. It is filtered to SQLite's extensions
  (`.db`, `.db3`, `.sqlite`, `.sqlite3`, plus "All files" for a
  database with no extension at all) and starts in the directory of the
  database you already have open.
- **Open database…** (or **Ctrl+O**) is the built-in picker: a path
  field and a listing of the directory around it.

The picker is not a fallback nobody looked after. It is what still works
where the system dialog does not — a browser has no filesystem paths at
all, and a Wayland session with no desktop portal installed has no portal
to ask. Every failure the dialog can report says so in the status line and
points at the picker, rather than leaving a button that quietly does
nothing.

### How the dialog is tested

A test build cannot click a native dialog, and glinlandui's test build
selects a portable stub whose only answer is `error.Unsupported` — so the
whole Browse path was unreachable past the call. The toolkit now ships a
**scriptable dialog** (`glinlandui.file_dialog.fake`): install a `Fake` and
the same three entry points answer from it. It is opt-in, so with nothing
installed the behaviour is exactly the stub's, and `platform.zig` is
untouched — the cross-platform parity contract still holds.

`dialog.zig` resolves the backend it calls:

```zig
const backend = if (builtin.is_test) ui.file_dialog.fake else ui.file_dialog;
```

so production is the real backend on every host and a test drives the fake.
The `Fake` also records what it was *asked* for — kind, title, starting
folder, the whole filter list — so a test asserts the request and not only
the answer. That is what catches a dialog opening in the wrong directory,
or a filter list drifting from the picker's extension list.

The e2e tests then click the real Browse button through the real host and
assert on what the app did: which database is open, what the status line
says, and what the frame draws. Writing them found a real bug —
`browse()` returned a path borrowed from the `Selection` it frees on
return, a use-after-free on every successful Browse.

### Cross-compiling

| target | CLI | GUI |
|---|---|---|
| `x86_64-linux` | ✅ | ✅ (needs a Wayland toolchain) |
| `x86_64-windows` | ✅ | ✅ |
| `aarch64-macos` | ✅ | needs the macOS SDK for AppKit |

The macOS GUI cannot be linked from Linux — AppKit, Foundation and
CoreGraphics ship only in the macOS SDK — so build that target on macOS
or with an SDK present. Everything else cross-compiles from here.

SQLite comes from the system library when one is present and from the
vendored amalgamation otherwise, which is what makes cross-compiling
work.

## The GUI

glinlandui provides the window, event loop, layout engine, text
rasteriser, fifteen basic controls and a headless test driver. It does
**not** provide a data grid, a tree view, or a multi-line text editor —
and for a database browser those three are the product. So they are built
from the primitives, in `src/gui/`:

- **`grid.zig`** virtualises rows and columns. This is a correctness
  requirement, not an optimisation: `click_registry.cap` is 256 entries
  per frame and silently drops the rest, so a grid registering one
  target per row would stop responding at row 256. macOS and Windows
  also rasterize on the CPU, so per-frame cell count is the frame cost.
- **`editor.zig`** is a plain byte buffer with a byte-offset caret,
  drawn one line at a time. `input` is single-line ASCII by design.
- **`theme.zig`** holds the palette. Its tests assert *relationships*
  (NULL dimmer than a value, stripes close but distinguishable) rather
  than exact colours, so the palette can be retuned without rewriting
  tests.

The GUI's 135 tests run headless — glinlandui's test build selects a
portable backend, and the Driver renders real frames, so widget wiring
is verified with no display server on any platform.

Of those, `e2e_test.zig` drives the **real** `App`: it types a query one
keystroke at a time through the app's own key handler, presses Ctrl+Enter,
and then asserts the output appears in the rendered frame. That last step
matters. Asserting only on `App.result` would pass even if the grid
rendered blank — and it did, until these tests caught it.

### Known limits

- The binding's `exec` path discards SQLite's error message, so a failed
  `INSERT` reports the error name only. A failure raised while *stepping*
  a prepared statement keeps SQLite's wording.
- No row editor. Writes happen by running SQL, so nothing in either
  frontend can corrupt a value it did not construct.
- The interactive CLI REPL does not reliably accumulate a multi-line
  statement; use `-c` or `--stdin` for scripts. The GUI editor handles
  multi-line input correctly.
- The GUI's schema tree is capped at 200 visible tables; beyond that it
  shows a count rather than scrolling.
- The GUI keeps each frame's label text in a 512 KB arena that resets
  every frame. A result set wide enough to exhaust it (hundreds of
  columns) draws those cells blank rather than failing.
- macOS/Windows render on the CPU, so the grid is deliberately capped
  rather than virtualised to the pixel.
