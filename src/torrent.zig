const std = @import("std");
const Peer = @import("peer.zig").Peer;
const TorrentFile = @import("torrent_file.zig").TorrentFile;

pub const Torrent = struct {
    const Self: @This();
    // peers is a list of seeders we can connect to
    peers: []Peer,
    // unique idee to identify ourselves to others
    peer_id: [20]u8,
    // the corresponding torrent file that contains its meta data.
    file: *TorrentFile,

    /// Downloads the torrent and writes to the given stream
    pub fn download(self: Self, stream: var) !void {
        std.debug.warn("Downloaded started for torrent: {}\n", .{self.file.name});
    }

    /// Returns the bounds of a piece by its index
    fn bounds(
        self: Self,
        index: usize,
        begin: *usize,
        end: *usize,
    ) void {
        const meta = self.file;
        begin.* = index * meta.piece_length;
        end.* = blk: {
            var length = begin + meta.piece_length;
            if (length > meta.length) {
                length = meta.length;
            }
            break :blk length;
        };
    }

    /// Calculates and returns the piece size
    fn pieceSize(self: Self, index: usize) usize {
        var begin: usize = undefined;
        var end: usize = undefined;
        self.bound(index, &begin, &end);
        return end - begin;
    }
};
