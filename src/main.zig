const std = @import("std");
const ramen = @import("ramen.zig");
const TorrentFile = ramen.TorrentFile;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // arena for our args
    var arena = std.heap.ArenaAllocator.init(&gpa.allocator);
    defer arena.deinit();

    const std_in = std.io.getStdIn().writer();

    var file_path: ?[]const u8 = null;
    var dir_path: ?[]const u8 = null;

    var args_iterator = std.process.ArgIterator.init();
    var index: usize = 0;
    while (args_iterator.next(&arena.allocator)) |maybe_arg| : (index += 1) {
        const arg = maybe_arg catch continue;
        if (index == 1) {
            file_path = arg;
        }

        if (std.mem.eql(u8, arg, "-d")) {
            if (args_iterator.next(&arena.allocator)) |maybe_dir_path| {
                dir_path = maybe_dir_path catch continue;
            }
        }
    }

    const path = file_path orelse {
        try std_in.writeAll("Missing file argument\n");
        return;
    };

    var torrent = try TorrentFile.open(&gpa.allocator, path);
    defer torrent.deinit(&gpa.allocator);

    torrent.download(&gpa.allocator, dir_path) catch |err| {
        std.debug.print("Could not download torrent: {s}\n", .{err});
        return err;
    };
}
