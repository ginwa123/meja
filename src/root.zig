//! meja core — the reusable, platform-agnostic heart of the app.
//!
//! Both frontends (the CLI in `src/cli`, the GUI in `src/gui`) are thin
//! shells over this library. Nothing in here may depend on a frontend.
//!
//! ## Why this layer exists
//!
//! The `databases` binding underneath us is thin — deliberately so, but
//! thin enough that a database *client* has to supply three things it
//! does not expose:
//!
//!  1. **Statement splitting.** `sqlite3_prepare_v2` is called with a
//!     NULL tail pointer, so only the first statement in a string runs.
//!     See `sql.splitStatements`.
//!  2. **Column names.** `sqlite3_column_name` is never called, so a
//!     `Row` is a bare `[][]u8`. See `select_list` for how the app
//!     recovers names, and `query` for how it pairs them with values.
//!  3. **Types and NULL.** Every value comes back as its text rendering,
//!     and NULL arrives as a zero-length slice — indistinguishable from
//!     the empty string. See `value` and the `typeof()` rewriting in
//!     `query`.

const std = @import("std");

pub const sql = @import("core/sql.zig");

test {
    _ = sql;
}
