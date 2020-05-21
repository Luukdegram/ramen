const std = @import("std");
const TorrentFile = @import("torrent_file.zig").TorrentFile;

pub fn main() anyerror!void {
    const allocator = &std.heap.ArenaAllocator.init(std.heap.page_allocator).allocator;
    var path = "debian-10.4.0-arm64-netinst.iso.torrent";
    var torrent = try TorrentFile.open(allocator, path);
    defer torrent.deinit();

    var save_path = "bin";
    torrent.download(save_path) catch |err| {
        std.debug.warn("Could not download torrent:\n", .{});
        return err;
    };
}
