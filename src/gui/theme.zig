//! Colours and metrics for the GUI, in one place so the palette can be read and changed.

const ui = @import("glinlandui");
const Color = ui.Color;

// Surfaces, from furthest back to nearest.
pub const bg_app = Color.hexC("#141416");
pub const bg_panel = Color.hexC("#1a1a1d");
pub const bg_editor = Color.hexC("#101014");
pub const bg_header = Color.hexC("#22222a");
pub const bg_selected = Color.hexC("#2d3a52");
pub const bg_hover = Color.hexC("#20202a");
pub const bg_tab = Color.hexC("#1a1a1d");
pub const bg_tab_active = Color.hexC("#141416");
pub const bg_chip = Color.hexC("#22222a");
pub const bg_primary = Color.hexC("#2b3d55");
pub const bg_primary_hover = Color.hexC("#33475f");

// Grid zebra striping, very close in value so the stripes aid scanning without turning the table into a barcode.
pub const bg_row_even = Color.hexC("#17171a");
pub const bg_row_odd = Color.hexC("#1c1c20");

// Text.
pub const text = Color.hexC("#d8d8dc");
pub const text_bright = Color.hexC("#f0f0f4");
pub const text_dim = Color.hexC("#8a8a94");
pub const text_faint = Color.hexC("#5a5a64");
pub const text_ghost = Color.hexC("#3f3f49");

/// NULL, deliberately dimmer than a real value so a column of NULLs reads as mostly empty.
pub const text_null_value = Color.hexC("#4f6a8a");

// Accents.
pub const accent = Color.hexC("#7aa2c4");
pub const ok = Color.hexC("#7fae8a");
pub const warn = Color.hexC("#c8a45c");
pub const danger = Color.hexC("#c86a6a");

// Lines.
pub const line = Color.hexC("#26262c");
pub const line_soft = Color.hexC("#1f1f24");

// Metrics, in pixels.
pub const font_size: u16 = 14;
pub const font_size_small: u16 = 13;
pub const font_size_tiny: u16 = 11;

/// Advance width of one monospace glyph at `font_size`, which is what turns a click's x into a column.
pub const mono_char_w: f32 = 8.4;

/// One grid row, header included.
pub const row_height: u16 = 22;

/// One tree row. Taller than a grid row: a tree is read, a grid is scanned.
pub const tree_row_height: u16 = 24;

/// Horizontal padding inside a grid cell; column widths are computed from it.
pub const cell_padding: u16 = 6;

/// Width of the schema tree, wide enough for a 30-character table name at the small font.
pub const sidebar_width: f32 = 272;

// Chrome heights.
pub const topbar_h: f32 = 44;
pub const tabs_h: f32 = 34;
pub const status_h: f32 = 26;
pub const bar_h: f32 = 30;
pub const grip_h: f32 = 5;

/// Width of the row-number gutter in the grid.
pub const rownum_w: f32 = 44;

test "grid stripes are distinguishable but close" {
    // Too strong makes a wide table hard to read across; too weak and it does nothing.
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
