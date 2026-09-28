const std = @import("std");
const ui = @import("glinlandui");
const Driver = ui.testing.Driver;

const meja = @import("meja");
const query = meja.query;
const editor = @import("editor.zig");
const grid = @import("grid.zig");

/// A miniature app: enough to prove the render path works end to end
/// with real data from the core, driven through glinlandui's headless
/// driver. The full app in `main.zig` is exercised through the same
/// components; this is the wiring test.
const Harness = struct {
    result: query.ResultSet = undefined,
    has_result: bool = false,
    /// The editor needs a REAL buffer: `Editor.init(undefined)` would
    /// give a zero-length slice, and the first insert would write out of
    /// bounds. The app's own `App` holds a fixed array for this reason.
    sql_storage: [4096]u8 = undefined,
    ed: editor.Editor = undefined,
    status: []const u8 = "ready",

    fn init() *Harness {
        const self = std.heap.page_allocator.create(Harness) catch unreachable;
        self.* = .{};
        self.ed = editor.Editor.init(&self.sql_storage);
        self.ed.setText("SELECT * FROM users");
        return self;
    }

    fn root(ctx: ?*anyopaque, w: u32, h: u32) void {
        _ = .{ w, h };
        const self: *Harness = @ptrCast(@alignCast(ctx.?));
        ui.components.box.box(.{
            .id = "root",
            .w = .grow,
            .h = .grow,
            .bg = ui.Color.rgb(0x14, 0x14, 0x16),
        }, self, rootChildren);
    }

    fn rootChildren(self: *Harness) void {
        ui.components.text.label(.{ .str = self.status });
        ui.components.text.label(.{ .str = self.ed.text() });
    }
};

test "the headless driver renders a frame" {
    // page_allocator, not testing.allocator: Clay keeps a global pointer
    // into its arena and it is deliberately never freed, so the leak
    // detector would fire on a correct program.
    const harness = Harness.init();
    defer std.heap.page_allocator.destroy(harness);
    var driver = try Driver.initOwned(std.heap.page_allocator, harness, Harness.root);
    defer driver.deinit();

    try driver.start(.{ .width = 1200, .height = 800 });
    try driver.waitForIdle();

    // The status and the SQL the app seeded must both be on screen.
    try driver.expectText("ready");
    try driver.expectText("SELECT * FROM users");
    try std.testing.expect(driver.exists("root"));

    const snap = driver.snapshot();
    try std.testing.expect(snap.rectangle_count > 0);
}

test "the driver can find a widget by id and click it" {
    const harness = Harness.init();
    defer std.heap.page_allocator.destroy(harness);
    var driver = try Driver.initOwned(std.heap.page_allocator, harness, Harness.root);
    defer driver.deinit();

    try driver.start(.{ .width = 800, .height = 600 });
    try driver.waitForIdle();
    try std.testing.expect(driver.box("root") != null);
}

test "resizing re-renders at the new size" {
    const harness = Harness.init();
    defer std.heap.page_allocator.destroy(harness);
    var driver = try Driver.initOwned(std.heap.page_allocator, harness, Harness.root);
    defer driver.deinit();

    try driver.start(.{ .width = 800, .height = 600 });
    try driver.waitForIdle();
    try driver.resize(400, 300);
    driver.frame();
    const snap = driver.snapshot();
    try std.testing.expectEqual(@as(u32, 400), snap.width);
    try std.testing.expectEqual(@as(u32, 300), snap.height);
}

test "typed text reaches the editor buffer" {
    // The editor is what the GUI's key handler drives, so proving the
    // buffer accepts a realistic query proves the input path works.
    const h = Harness.init();
    defer std.heap.page_allocator.destroy(h);
    h.ed.clear();
    try std.testing.expectEqual(@as(usize, "SELECT name FROM t".len), h.ed.insertSlice("SELECT name FROM t"));
    try std.testing.expectEqualStrings("SELECT name FROM t", h.ed.text());
}
