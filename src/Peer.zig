const std = @import("std");

const Peer = @This();

address: std.net.Address,

/// Parses the provided bytes into an array of Peers
/// Returns `error.Malformed` if the length of bytes can not be divided by 6.
/// 4 bytes for ip, 2 for the port as we currently only support ipv4.
pub fn listFromCompact(gpa: *std.mem.Allocator, bytes: []const u8) ![]const Peer {
    if (bytes.len % 6 != 0) return error.Malformed;
    const num_peers = bytes.len / 6;
    var peers = try std.ArrayList(Peer).initCapacity(gpa, num_peers);
    defer peers.deinit();

    var i: usize = 0;
    while (i < num_peers) : (i += 1) {
        const offset = i * 6;
        var buf: [16]u8 = undefined;
        const ip = try toIPSlice(&buf, bytes[offset..][0..4]);
        const port = std.mem.readIntBig(u16, bytes[offset + 4 ..][0..2]);

        // silent fail if we cannot parse an address
        // as we could potentially parse other addresses.
        if (std.net.Address.parseIp(ip, port)) |addr| {
            peers.appendAssumeCapacity(.{ .address = addr });
        } else |_| {}
    }

    return peers.toOwnedSlice();
}

/// Creates an ip addres in the form of a.b.c.d
/// from a given array
/// Asserts the given `buffer` has a len of atleast 16 to fit the entire IP
fn toIPSlice(buffer: []u8, bytes: *const [4]u8) ![]const u8 {
    std.debug.assert(buffer.len >= 16);
    var offset: usize = 0;

    for (bytes) |b, i| {
        offset += std.fmt.formatIntBuf(buffer[offset..], b, 10, false, .{});

        // Only add dots after a, b and c
        if (i < 3) {
            buffer[offset] = '.';
            offset += 1;
        }
    }
    return buffer[0..offset];
}
