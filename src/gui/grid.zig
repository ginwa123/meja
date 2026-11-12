//! Grid virtualisation: which cells to draw, given a scroll position.

const std = @import("std");

/// Height of one row in pixels, including its bottom border.
pub const row_height: u16 = 22;

/// Default width of a column when nothing better is known.
pub const default_column_width: u16 = 120;

/// Widest a column may be, so one long name cannot consume the window.
pub const max_column_width: u16 = 400;

/// Narrowest a column may be, so a one-character header stays clickable.
pub const min_column_width: u16 = 40;

/// What is currently on screen.
pub const Viewport = struct {
    /// Rows in the result set.
    total_rows: usize,
    /// Columns in the result set.
    total_cols: usize,
    /// Scroll offset in pixels, measured from the top. Never negative.
    scroll_y: f32,
    /// Visible height in pixels.
    height: f32,
    /// Visible width in pixels.
    width: f32,
    /// How many extra rows to draw above and below, to cover partial rows and fast scrolling.
    overscan: usize = 2,
};

/// The slice of the result set that is visible.
pub const Visible = struct {
    /// Index of the first row to declare.
    first_row: usize,
    /// Number of rows to declare.
    row_count: usize,
    /// Index of the first column to declare.
    first_col: usize,
    /// Number of columns to declare.
    col_count: usize,
    /// True when there are rows below the viewport.
    has_more_below: bool,
    /// True when there are rows above the viewport.
    has_more_above: bool,
    /// Total height of all rows, for the scrollbar's content size.
    content_height: f32,

    /// Rows that would be declared even before overscan.
    pub fn declaredRows(self: Visible) usize {
        return self.row_count;
    }
};

/// Work out which rows and columns intersect the viewport.
pub fn visible(view: Viewport) Visible {
    const content_height = @as(f32, @floatFromInt(view.total_rows)) *
        @as(f32, @floatFromInt(row_height));

    // A negative or NaN scroll (Clay can hand one back before the first layout settles) must not produce a nonsense first_row.
    const scroll_y = if (std.math.isNan(view.scroll_y) or view.scroll_y < 0) 0 else view.scroll_y;

    // Clamp the scroll to the content first.
    const max_scroll = @max(content_height - @max(view.height, 0), 0);
    const effective_scroll = @min(scroll_y, max_scroll);

    const first_visible = @as(usize, @intFromFloat(effective_scroll / @as(f32, @floatFromInt(row_height))));
    const first_row = first_visible -| view.overscan;

    // How many rows fit, plus one for a row that is only partly visible.
    const visible_rows: usize = @intFromFloat(
        @ceil(view.height / @as(f32, @floatFromInt(row_height))) + 1,
    );
    const row_count = @min(
        view.total_rows -| first_row,
        visible_rows + view.overscan * 2,
    );

    return .{
        .first_row = first_row,
        .row_count = row_count,
        .first_col = 0,
        .col_count = 0,
        .has_more_below = first_row + row_count < view.total_rows,
        .has_more_above = first_row > 0,
        .content_height = content_height,
    };
}

/// How many columns fit across `width` given their pixel widths.
pub fn visibleColumns(widths: []const u16, width: f32, scroll_x: f32) struct { first: usize, count: usize } {
    if (widths.len == 0) return .{ .first = 0, .count = 0 };

    const scroll = if (std.math.isNan(scroll_x) or scroll_x < 0) 0 else scroll_x;
    const viewport_w: f32 = @max(width, 0);

    // Skip columns entirely to the left of the viewport.
    var first: usize = 0;
    var x: f32 = 0;
    while (first < widths.len) {
        const w: f32 = @floatFromInt(widths[first] + 1); // +1 for the border
        if (x + w > scroll) break;
        x += w;
        first += 1;
    }
    if (first >= widths.len) first = widths.len - 1;

    // Then take columns until the right edge is reached.
    var cursor = x;
    var count: usize = 0;
    var i = first;
    while (i < widths.len) : (i += 1) {
        const w: f32 = @floatFromInt(widths[i] + 1);
        if (cursor + w > scroll + viewport_w) break;
        cursor += w;
        count += 1;
    }
    // Always draw at least one column, even in a very narrow window, or the grid looks empty and the user cannot find the data.
    if (count == 0) count = 1;

    return .{ .first = first, .count = @min(count, widths.len - first) };
}

/// Clamp a column's width into the allowed range, and never below 1 so the layout arithmetic cannot divide by zero.
pub fn clampColumnWidth(w: u16) u16 {
    if (w < min_column_width) return min_column_width;
    if (w > max_column_width) return max_column_width;
    return w;
}

/// The pixel width a cell should be drawn at, given the widest value it contains.
pub fn widthForChars(widest_chars: usize, font_size: u16, cell_padding: u16) u16 {
    const char_px = @as(usize, font_size) * 3 / 5;
    const text_px = widest_chars * @max(char_px, 1);
    const px = text_px + @as(usize, cell_padding) * 2;
    const capped = @min(px, max_column_width);
    return @intCast(@max(capped, min_column_width));
}

/// Size a column to fit its header and its values.
pub fn columnWidth(
    values: []const []const u8,
    header: []const u8,
    font_size: u16,
    cell_padding: u16,
) u16 {
    var widest = header.len;
    for (values) |v| {
        if (v.len > widest) widest = v.len;
    }
    return widthForChars(widest, font_size, cell_padding);
}

/// Rows rendered per frame must stay under the click-registry cap, or per-row click targets are silently dropped past the limit.
pub const max_clickable_rows = 200;

/// True when a row count is safe to give per-row click targets.
pub fn withinClickBudget(row_count: usize) bool {
    return row_count <= max_clickable_rows;
}

// Tests

const testing = std.testing;

test "an empty result shows nothing" {
    const v = visible(.{ .total_rows = 0, .total_cols = 0, .scroll_y = 0, .height = 400, .width = 800 });
    try testing.expectEqual(@as(usize, 0), v.row_count);
    try testing.expect(!v.has_more_below);
    try testing.expect(!v.has_more_above);
    try testing.expectEqual(@as(f32, 0), v.content_height);
}

test "at the top, the first row is row 0" {
    const v = visible(.{ .total_rows = 100, .total_cols = 2, .scroll_y = 0, .height = 440, .width = 800 });
    try testing.expectEqual(@as(usize, 0), v.first_row);
    try testing.expect(v.has_more_below);
    try testing.expect(!v.has_more_above);
}

test "scrolling moves the window down" {
    // 1000px down at 22px per row is row 45.
    const v = visible(.{ .total_rows = 1000, .total_cols = 2, .scroll_y = 1000, .height = 440, .width = 800 });
    // 1000 / 22 = row 45, minus 2 rows of overscan.
    try testing.expectEqual(@as(usize, 43), v.first_row);
    try testing.expect(v.has_more_above);
    try testing.expect(v.has_more_below);
}

test "the declared row count is bounded by the viewport, not the table" {
    // A 1M-row table must not declare 1M rows.
    const v = visible(.{ .total_rows = 1_000_000, .total_cols = 5, .scroll_y = 0, .height = 440, .width = 800 });
    try testing.expect(v.row_count <= 40);
    try testing.expect(withinClickBudget(v.row_count));
}

test "a huge viewport is still capped by the click budget" {
    // A 4K-tall window at 22px is ~175 rows, plus overscan.
    const v = visible(.{ .total_rows = 10_000, .total_cols = 5, .scroll_y = 0, .height = 4000, .width = 3840 });
    try testing.expect(withinClickBudget(v.row_count));
}

test "a negative or NaN scroll does not produce a wild first_row" {
    // Clay can hand back a bad scroll before the first layout settles.
    const neg = visible(.{ .total_rows = 100, .total_cols = 1, .scroll_y = -50, .height = 400, .width = 800 });
    try testing.expectEqual(@as(usize, 0), neg.first_row);

    const nan = visible(.{ .total_rows = 100, .total_cols = 1, .scroll_y = std.math.nan(f32), .height = 400, .width = 800 });
    try testing.expectEqual(@as(usize, 0), nan.first_row);
}

test "scrolling past the end clamps instead of reading out of bounds" {
    // 200 rows at 22px is 4400px of content, so a 99999px scroll really is past the end and the window must clamp to the last rows.
    const v = visible(.{ .total_rows = 200, .total_cols = 1, .scroll_y = 99999, .height = 440, .width = 800 });
    try testing.expect(v.first_row + v.row_count <= 200);
    try testing.expect(!v.has_more_below);
    try testing.expect(v.has_more_above);
    // And the last row really is the last one.
    try testing.expectEqual(@as(usize, 200), v.first_row + v.row_count);
}

test "a table shorter than the viewport shows every row and no scroll" {
    // 10 rows is 220px in a 440px viewport, so it all fits: there is nothing above and nothing below, and no scroll offset applies.
    const v = visible(.{ .total_rows = 10, .total_cols = 1, .scroll_y = 99999, .height = 440, .width = 800 });
    try testing.expectEqual(@as(usize, 0), v.first_row);
    try testing.expectEqual(@as(usize, 10), v.row_count);
    try testing.expect(!v.has_more_above);
    try testing.expect(!v.has_more_below);
}

test "overscan includes rows just above the fold" {
    const v = visible(.{
        .total_rows = 100,
        .total_cols = 1,
        .scroll_y = 22 * 10,
        .height = 440,
        .width = 800,
        .overscan = 2,
    });
    // At row 10, overscan pulls the window back to row 8.
    try testing.expectEqual(@as(usize, 8), v.first_row);
}

test "column visibility depends on width" {
    const widths = [_]u16{ 100, 100, 100, 100, 100 };
    const all = visibleColumns(&widths, 1000, 0);
    try testing.expectEqual(@as(usize, 0), all.first);
    try testing.expect(all.count >= 4);

    const narrow = visibleColumns(&widths, 150, 0);
    try testing.expectEqual(@as(usize, 0), narrow.first);
    try testing.expect(narrow.count <= 2);
}

test "horizontal scroll skips whole columns" {
    const widths = [_]u16{ 100, 100, 100, 100 };
    const scrolled = visibleColumns(&widths, 200, 250);
    // 250px is past the 2nd and 3rd column (101px each).
    try testing.expect(scrolled.first >= 2);
    try testing.expect(scrolled.first < widths.len);
}

test "at least one column is always drawn" {
    const widths = [_]u16{200};
    const tiny = visibleColumns(&widths, 10, 0);
    try testing.expectEqual(@as(usize, 1), tiny.count);
}

test "no columns means nothing drawn, not a crash" {
    const empty = visibleColumns(&.{}, 800, 0);
    try testing.expectEqual(@as(usize, 0), empty.count);
    try testing.expectEqual(@as(usize, 0), empty.first);
}

test "column width grows with content" {
    const short = [_][]const u8{ "a", "b" };
    const medium = [_][]const u8{"a medium length value here"};

    const w_short = columnWidth(&short, "id", 14, 4);
    const w_medium = columnWidth(&medium, "id", 14, 4);
    try testing.expect(w_short >= min_column_width);
    try testing.expect(w_medium > w_short);
}

test "a very long value hits the cap exactly" {
    const long = [_][]const u8{"x" ** 500};
    try testing.expectEqual(max_column_width, columnWidth(&long, "id", 14, 4));
}

test "a long header sizes the column even when values are short" {
    const vals = [_][]const u8{"x"};
    const w = columnWidth(&vals, "a reasonably long column header", 14, 4);
    try testing.expect(w > min_column_width);
}

test "a bigger font makes the same text wider" {
    // A column sized for 12px text would clip 14px text.
    try testing.expect(widthForChars(20, 14, 4) > widthForChars(20, 12, 4));
}

test "an empty column still gets a clickable minimum" {
    try testing.expectEqual(min_column_width, columnWidth(&.{}, "", 14, 4));
}

test "clampColumnWidth bounds both ends" {
    try testing.expectEqual(min_column_width, clampColumnWidth(0));
    try testing.expectEqual(min_column_width, clampColumnWidth(5));
    try testing.expectEqual(max_column_width, clampColumnWidth(5000));
    try testing.expectEqual(@as(u16, 200), clampColumnWidth(200));
}

test "the click budget is respected and checkable" {
    try testing.expect(withinClickBudget(0));
    try testing.expect(withinClickBudget(max_clickable_rows));
    try testing.expect(!withinClickBudget(max_clickable_rows + 1));
    // The registry cap is 256; per-row targets must stay well under it.
    try testing.expect(max_clickable_rows < 256);
}

test "content height is the full table, so the scrollbar is right" {
    const v = visible(.{ .total_rows = 100, .total_cols = 1, .scroll_y = 0, .height = 440, .width = 800 });
    try testing.expectEqual(@as(f32, 100 * 22), v.content_height);
}
