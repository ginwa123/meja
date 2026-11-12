# AGENTS.md — meja

Rules for anyone (human or agent) changing this repository.

## The non-negotiables

1. **macOS works first.** This machine is macOS (Apple silicon). Before you claim any change is
   done, `zig build` and `zig build test` must pass **here**. Linux and Windows are nice to have;
   macOS is the gate.
2. **The linter is zginlint.** Not `zig fmt` alone. `zig build zginlint:check` must report
   **zero findings** — there is no baseline, no pin file, and no suppression comment.
3. **A comment block is at most ONE line.** Write as many comments as you like — there is no
   limit on the number — but each block is a single line. A blank line or a line of code ends a
   block, so a trailing `// note` after code is always fine.
4. **No `.zig` file may exceed 3000 lines.** Split the module instead of growing the file. The
   largest file today is `src/gui/e2e_test.zig` at ~1145 lines, so there is room — but the cap
   is a hard ceiling, not a target.

## Verify before you report

```sh
zig build                  # both binaries: meja (CLI) + meja-gui
zig build test             # core + CLI + GUI tests (254 on macOS)
zig build zginlint:check   # the lint gate: 0 findings or fix it
zig build lines:check      # no .zig file over 3000 lines
```

A change that fails any of those four is not finished. Do not describe a build as working
unless you ran it on this host and saw it exit 0.

## The rules zginlint enforces

| rule | what it means |
|---|---|
| `zginlint/max-comment-lines` | a comment block is at most **1** line (`--max-comment-lines 1`) |
| `zginlint/no-catch-unreachable` | banned — it panics with no message in Debug/ReleaseSafe and is UB in ReleaseFast. Use `catch @panic("what failed")` or, better, `try` |
| `zginlint/no-std-log-warn` | a bare `std.log.warn` is banned; it writes to the test runner's stderr and makes a green suite read as broken |

`///` doc comments and `//!` container docs are comments like any other: one line, no exemption.
A block that needs more than one line belongs in the README, a design doc, or the commit message.

## Layout

```
src/root.zig        the `meja` library module — the only thing frontends share
src/core/           SQL splitting, values, schema introspection, the query engine
src/cli/            the terminal frontend (no display server needed)
src/gui/            the glinlandui frontend
build.zig           targets, steps, the zginlint gate
build.zig.zon       deps, all local path deps plus the zginlint pin
```

Both frontends depend on the `meja` module and contain no data-access logic of their own. That
is what keeps them in sync — do not copy query code into `src/cli/` or `src/gui/`.

## Build steps

```sh
zig build                     # both binaries
zig build test                # everything (core + CLI + GUI)
zig build test-gui            # GUI tests only, headless
zig build run -- app.db       # run the CLI
zig build run-gui -- app.db   # run the GUI
zig build inspect -- app.db   # render one real frame and print what it drew
zig build zginlint            # install the linter into zig-out/bin/zginlint
zig build zginlint:check      # the gate

zig build -Dgui=false         # CLI only, no glinlandui dependency needed
zig build test -Ddb_used=sqlite,postgres   # also compile the libpq backend
```

## Dependencies

Both are **local path deps**, relative to this file, because Zig 0.16 rejects absolute paths in
`build.zig.zon`:

| dep | path | provides |
|---|---|---|
| `databases` | `../ruangsql` | sqlite3 + libpq bindings |
| `glinlandui` | `../glinlandui` | the GUI toolkit, including the system file dialog |
| `zginlint` | URL + hash | the linter |

They must be checked out as siblings of this repo:

```sh
git clone https://github.com/ginwa123/ruangsql.git  ../ruangsql
git clone https://github.com/ginwa123/glinlandui.git ../glinlandui
```

Without `../ruangsql` the build dies before compiling anything, with
`unable to open '.../../ruangsql': FileNotFound`.

## Testing

- Tests live beside the code they test, in the same file.
- `zig build test` runs three binaries: the core module, the CLI, and the GUI. The GUI suite is
  headless — glinlandui selects a portable backend under `builtin.is_test`, so it needs no
  display server on any platform.
- `src/gui/e2e_test.zig` drives the **real** `App`: it types a query one keystroke at a time,
  presses Ctrl+Enter, and asserts the output appears in the *rendered frame*. Asserting only on
  `App.result` would pass even if the grid drew blank.
- A test that writes to stderr fails the suite even when it passes. That is why
  `zginlint/no-std-log-warn` exists; the same applies to any stray `std.debug.print`.

## GUI notes

- `meja-gui` needs a window server. On macOS that is always there; on Linux it needs a Wayland
  compositor and reports `error.NoWaylandDisplay` rather than starting without one.
- Colours are packed `0xRRGGBB` `u32` values, which is what every glinlandui component prop
  takes. Keep the palette in `src/gui/theme.zig`.
- Clay element IDs must be **unique within a frame and must outlive the declare**. Build them
  from the frame arena (`app.claimText`), never from a local buffer — a local hands every row
  the same address, so every row gets the same id and Clay logs `duplicate_id` for each one.
- `click_registry.cap` is 256 entries per frame. A per-row click target therefore caps at ~200
  rows; that is what `grid.zig`'s virtualisation and `withinClickBudget` are for.

## Commits

One logical change per commit, and the message says *why*. The body is the place for the
multi-paragraph explanation a one-line comment cannot hold.
