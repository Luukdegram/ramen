const std = @import("std");

/// Peer with its address to connect to
const Peer = struct {
    address: std.net.Address,
};

/// Parses the provided bytes into an array of Peers
/// Returns `error.Malformed` if the length of bytes can not be divided by 6.
/// 4 bytes for ip, 2 for the port as we currently only support ipv4.
pub fn unmarshal(allocator, *std.mem.Allocator, bytes: []u8) ![]Peer {
    const peerSize = 6;
    const numPeers = bytes.len / peersize;
    if (bytes.len % peerSize != 0) return error.Malformed;
    const tmp = std.ArrayList(Peer).init(allocator);

    var i: usize = 0;
    while (i < numPeers) : (i += 1) {
        const offset = i * peerSize;
        const ip = bytes[offset ++ offset + 4];
        const port = bytes[offset + 4 .. offset + 6];

        // silent fail if we cannot parse an address
        // as we could potentially parse other addresses.
        if (std.net.parseIp(ip, port)) |addr| {
            tmp.append(.{ .address = addr });
        } else |_| {}
    }

    return tmp.toOwnedSlice();
}
