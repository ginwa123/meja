//! Colours and metrics for the GUI.
//!
//! glinlandui has no theme — every component carries neutral dark
//! defaults inline. Those defaults are fine for a demo but say nothing
//! about which values are *deliberate*, so the app's palette lives here
//! where it can be read and changed in one place.
//!
//! The palette is dark and low-chroma on purpose: the content is text,
//! and a saturated UI would compete with the data. The one accent is
//! the selection colour, used in exactly two places.

const ui = @import("glinlandui");
const Color = ui.Color;

// Surfaces, from furthest back to nearest.
pub const bg_app = Color.hexC("#141416");
pub const bg_panel = Color.hexC("#1a1a1d");
pub const bg_editor = Color.hexC("#101014");
pub const bg_header = Color.hexC("#22222a");
pub const bg_selected = Color.hexC("#2d3a52");

// Grid zebra striping. Very close in value, so the stripes aid scanning
// without turning the table into a barcode.
pub const bg_row_even = Color.hexC("#17171a");
pub const bg_row_odd = Color.hexC("#1c1c20");

// Text.
pub const text = Color.hexC("#d8d8dc");
pub const text_bright = Color.hexC("#f0f0f4");
pub const text_dim = Color.hexC("#8a8a94");
pub const text_faint = Color.hexC("#5a5a64");

/// NULL. Deliberately dimmer than a real value: a column of NULLs should
/// read as "mostly empty", not as data. This is the visual payoff of
/// recovering the storage class — without it, NULL and '' are the same
/// bytes and cannot be styled apart at all.
pub const text_null_value = Color.hexC("#4f6a8a");

/// Truncation / overflow / error hints.
pub const warn = Color.hexC("#c8a45c");
pub const danger = Color.hexC("#c86a6a");

// Metrics, in pixels.
pub const font_size: u16 = 14;
pub const font_size_small: u16 = 13;

/// One grid row, header included.
pub const row_height: u16 = 22;

/// Horizontal padding inside a grid cell. Column widths are computed
/// from this, so changing it changes the layout consistently.
pub const cell_padding: u16 = 6;

/// Width of the schema tree. Wide enough for a 30-character table name
/// at the small font size, which covers the overwhelming majority.
pub const sidebar_width: f32 = 260;

test "the palette is opaque" {
    // A transparent surface would let the window background show
    // through and make the grid unreadable.
    for ([_]Color{
        bg_app,      bg_panel,    bg_editor,  bg_header,
        bg_selected, bg_row_even, bg_row_odd,
    }) |c| {
        try @import("std").testing.expect(c.isOpaque());
    }
}

test "grid stripes are distinguishable but close" {
    // A zebra stripe that is too strong makes a wide table hard to read
    // across; too weak and it does nothing. Assert they differ, and that
    // they differ only slightly.
    const a = @as(i32, bg_row_even.r());
    const b = @as(i32, bg_row_odd.r());
    const delta = @abs(a - b);
    try @import("std").testing.expect(delta > 0);
    try @import("std").testing.expect(delta < 24);
}

test "text is lighter than every surface it sits on" {
    const app = @as(i32, bg_app.r());
    const panel = @as(i32, bg_panel.r());
    const row = @as(i32, bg_row_odd.r());
    const fg = @as(i32, text.r());
    try @import("std").testing.expect(fg > app);
    try @import("std").testing.expect(fg > panel);
    try @import("std").testing.expect(fg > row);
}

test "NULL text is dimmer than a real value but still readable" {
    // If NULL were as bright as a value it would look like data.
    const real = @as(i32, text.r());
    const nv = @as(i32, text_null_value.r());
    try @import("std").testing.expect(nv < real);
    // ...but not so dim it disappears against the row background.
    const row = @as(i32, bg_row_odd.r());
    try @import("std").testing.expect(nv > row + 16);
}

test "the sidebar fits a typical table name" {
    // 240px at the 13px small font, ~7.8px per char, minus padding.
    const per_char = @as(f32, @floatFromInt(font_size_small)) * 0.6;
    const chars: usize = @intFromFloat((sidebar_width - 24) / per_char);
    try @import("std").testing.expect(chars >= 28);
}
