const std = @import("std");
const TorrentFile = @import("torrent_file.zig").TorrentFile;

pub fn main() anyerror!void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    // defer _ = gpa.deinit();

    var path = "bin/TrueNAS-12.0-U3.iso.torrent";
    var torrent = try TorrentFile.open(&gpa.allocator, path);
    defer torrent.deinit(&gpa.allocator);

    var save_path = "bin";
    torrent.download(&gpa.allocator, save_path) catch |err| {
        std.debug.print("Could not download torrent: {s}\n", .{err});
        return err;
    };
}
