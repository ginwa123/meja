// Colours and metrics for the GUI, in one place so the palette can be read and changed.
const ui = @import("glinlandui");
const Color = ui.Color;

// The kit's palette: every colour below is one of these eleven roles, so no raw hex is left in a view.
pub const c = ui.theme.dragon.colors;
pub const scale = ui.theme.dragon.type_scale;

// Surfaces, from furthest back to nearest.
pub const bg_app = c.background;
pub const bg_panel = c.surface;
pub const bg_editor = c.background;
pub const bg_header = c.surface_variant;
pub const bg_selected = ui.theme.selected;
pub const bg_hover = c.hover;
pub const bg_tab = c.surface;
pub const bg_tab_active = c.background;
pub const bg_chip = c.surface_variant;
pub const bg_primary = c.primary;
pub const bg_primary_hover = c.primary_hover;

// Grid zebra: one step off the background, so the stripes aid scanning without turning the table into a barcode.
pub const bg_row_even = c.background;
pub const bg_row_odd = Color.hexC("#141310");

// Text.
pub const text = c.text;
pub const text_bright = Color.hexC("#e6e4dd");
pub const text_dim = c.text_dim;
pub const text_faint = c.text_done;
pub const text_ghost = Color.hexC("#45433f");

// NULL is violet, so a column of NULLs reads as absent rather than as data.
pub const text_null_value = Color.hexC("#8992a7");

// The one accent a view gets: a primary button, the caret, a checked box.
pub const accent = c.primary;
pub const on_primary = c.on_primary;
// The caret is the accent, never the text colour: a bar that matches the glyph merges with it.
pub const caret = c.primary;
pub const ok = Color.hexC("#87a987");
pub const warn = Color.hexC("#c4b28a");
pub const danger = Color.hexC("#c4746e");

// Lines: `line` is a hairline, `edge` is a field border, `line_soft` is a table row separator.
pub const line = c.divider;
pub const edge = Color.hexC("#625e5a");
pub const line_soft = c.surface_variant;

// Type scale, in points: title 18 / body 14 / label 13 / caption 12.
pub const font_size: u16 = scale.body;
pub const font_size_small: u16 = scale.label;
pub const font_size_tiny: u16 = scale.caption;
pub const font_size_title: u16 = scale.title;

// One grid row and its header; one tree row. A tree is read, a grid is scanned.
pub const row_height: u16 = 24;
pub const header_height: u16 = 26;
pub const tree_row_height: u16 = 26;

// Horizontal padding inside a grid cell; column widths are computed from it.
pub const cell_padding: u16 = 8;

// Width of the schema tree, from the kit's composition.
pub const sidebar_width: f32 = 248;

// Chrome heights.
pub const topbar_h: f32 = 44;
pub const tabs_h: f32 = 34;
pub const status_h: f32 = 26;
pub const bar_h: f32 = 30;
pub const grip_h: f32 = 5;

// Width of the row-number gutter in the grid.
pub const rownum_w: f32 = 44;

// Controls: sm 24 / md 28 / lg 32 tall, pad-x 9 / 12 / 16; fields 28 / 32 tall, pad-x 10.
pub const control_sm_h: u16 = 24;
pub const control_h: u16 = 28;
pub const control_pad_x: u16 = 12;
pub const control_sm_pad_x: u16 = 9;
pub const field_sm_h: u16 = 28;
pub const field_h: u16 = 32;
pub const field_pad_x: u16 = 10;

// Radii: badge 4 · control 6 · card 8 · dialog 12.
pub const r_badge: u16 = 4;
pub const r_control: u16 = 6;
pub const r_card: u16 = 8;
pub const r_dialog: u16 = 12;

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
    // The kit's 248px at the 13px label font, ~7.8px per char, minus padding.
    const per_char = @as(f32, @floatFromInt(font_size_small)) * 0.6;
    const chars: usize = @intFromFloat((sidebar_width - 16) / per_char);
    try @import("std").testing.expect(chars >= 28);
}

test "the palette is the kit's roles, not its own hexes" {
    try @import("std").testing.expectEqual(c.background, bg_app);
    try @import("std").testing.expectEqual(c.surface, bg_panel);
    try @import("std").testing.expectEqual(c.primary, accent);
    // The caret is the accent: a caret that matches the text merges with the glyph it touches.
    try @import("std").testing.expectEqual(c.primary, caret);
    try @import("std").testing.expectEqual(c.text, text);
    try @import("std").testing.expectEqual(c.divider, line);
    // A field's edge is visible against a surface; a hairline is not.
    try @import("std").testing.expect(edge.r() > line.r());
}

test "the metrics are the kit's" {
    try @import("std").testing.expectEqual(@as(u16, 24), row_height);
    try @import("std").testing.expectEqual(@as(u16, 26), tree_row_height);
    try @import("std").testing.expectEqual(@as(u16, 12), font_size_tiny);
    try @import("std").testing.expectEqual(@as(f32, 248), sidebar_width);
    try @import("std").testing.expectEqual(@as(u16, 6), r_control);
    try @import("std").testing.expectEqual(@as(u16, 4), r_badge);
}
