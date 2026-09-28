const std = @import("std");
const meja = @import("meja");
const databases = @import("databases");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    _ = io;
    _ = meja;
    _ = databases.database.backend_is_postgres;
}
