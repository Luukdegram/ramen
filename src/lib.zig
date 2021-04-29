pub const TorrentFile = @import("torrent_file.zig").TorrentFile;

test {
    _ = @import("torrent_file.zig");
    _ = @import("net/message.zig");
    _ = @import("net/Handshake.zig");
    _ = @import("bencode.zig");
}
