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
- **`meja-gui`** — a glinlandui window (optional; `-Dgui=false` drops it).

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
| `../glinlandui` | cross-platform GUI toolkit |

```sh
zig build                 # both binaries
zig build test            # 115 tests
zig build test -Dgui=false   # CLI only, no Wayland toolchain needed
zig build run -- app.db   # run the CLI
zig build run-gui         # run the GUI
```

SQLite comes from the system library when one is present and from the
vendored amalgamation otherwise, which is what makes cross-compiling
work.

### Known limits

- The binding's `exec` path discards SQLite's error message, so a failed
  `INSERT` reports the error name only. A failure raised while *stepping*
  a prepared statement keeps SQLite's wording.
- No write path beyond running SQL. There is no row editor, so nothing
  in the GUI or CLI can corrupt a value it did not construct.
- The GUI frontend is a build-and-link stub, not a browser window yet.
- The interactive REPL does not yet accumulate a multi-line statement
  across lines reliably; use `-c` or `--stdin` for scripts.
