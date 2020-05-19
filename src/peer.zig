const std = @import("std");

/// Peer with its address to connect to
pub const Peer = struct {
    address: std.net.Address,
    ip: []const u8,
};

/// Parses the provided bytes into an array of Peers
/// Returns `error.Malformed` if the length of bytes can not be divided by 6.
/// 4 bytes for ip, 2 for the port as we currently only support ipv4.
pub fn unmarshal(allocator: *std.mem.Allocator, bytes: []const u8) ![]Peer {
    const num_peers = bytes.len / 6;
    if (bytes.len % 6 != 0) return error.Malformed;
    var tmp = std.ArrayList(Peer).init(allocator);

    var i: usize = 0;
    while (i < num_peers) : (i += 1) {
        const offset = i * 6;
        var buffer: [4]u8 = undefined;
        std.mem.copy(u8, &buffer, bytes[offset .. offset + 4]);
        const ip = try ipString(allocator, buffer);
        const port = std.mem.readIntSliceBig(u16, bytes[offset + 4 .. offset + 6]);

        // silent fail if we cannot parse an address
        // as we could potentially parse other addresses.
        if (std.net.Address.parseIp(ip, port)) |addr| {
            try tmp.append(Peer{ .address = addr, .ip = ip });
        } else |_| {}
    }

    return tmp.toOwnedSlice();
}

/// Creates an ip addres in the form of a.b.c.d
fn ipString(allocator: *std.mem.Allocator, bytes: [4]u8) ![]const u8 {
    const max_ip = "255.255.255.255";
    var buffer = try allocator.alloc(u8, max_ip.len);

    var offset: usize = 0;
    for (bytes) |b, i| {
        const length = std.fmt.formatIntBuf(
            buffer[offset..],
            std.mem.readIntBig(u8, &bytes[i]),
            10,
            false,
            std.fmt.FormatOptions{},
        );
        offset += length;

        // Only add dots after a, b and c
        if (i < 3) {
            buffer[offset] = '.';
            offset += 1;
        }
    }
    return buffer[0..offset];
}
