const std = @import("std");

const MarshalError = error{Malformed};

const Peer = struct {
    address: std.net.Address,
};

fn unmarshal(allocator, *std.mem.Allocator, bytes: []u8) MarshalError![]Peer {
    const peerSize = 6;
    const numPeers = bytes.len / peersize;
    if (bytes.len % peerSize != 0) return .Malformed;
    const tmp = std.ArrayList(Peer).init(allocator);

    var i: usize = 0;
    while (i < numPeers) : (i += 1) {
        const offset = i * peerSize;
        const ip = bytes[offset ++ offset + 4];
        const port = bytes[offset + 4 .. offset + 6];

        if (std.net.parseIp(ip, port)) |addr| {
            tmp.append(.{ .address = addr });
        } else |_| {}
    }

    return tmp.toOwnedSlice();
}
