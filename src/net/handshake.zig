const std = @import("std");
const testing = std.testing;

/// Handshake identifies the connection between us and the peers
pub const Handshake = struct {
    p_str: []const u8 = "BitTorrent protocol",
    hash: [20]u8,
    peer: [20]u8,

    /// Creates a new Handshake instance
    pub fn init(hash: [20]u8, peer_id: [20]u8) Handshake {
        return .{
            .hash = hash,
            .peer = peer_id,
        };
    }

    /// Serializes a Handshake object into binary data
    /// Must be freed after use
    pub fn serialize(self: @This(), allocator: *std.mem.Allocator) ![]u8 {
        if (self.p_str.len > 19) return error.OutOfMemory;

        var buffer: []u8 = try allocator.alloc(u8, self.p_str.len + 49);
        std.mem.writeIntBig(u8, &buffer[0], @intCast(u8, self.p_str.len));
        std.mem.copy(u8, buffer[1..], self.p_str);
        var i: usize = self.p_str.len + 8 + 1; // 8 reserved bytes
        std.mem.copy(u8, buffer[i..], &self.hash);
        i += self.hash.len;
        std.mem.copy(u8, buffer[i..], &self.peer);
        i += self.peer.len;
        return buffer[0..i];
    }

    /// Reads from the `io.InStream` and parses the binary data into a `Handshake`
    /// Must be freed after use.
    pub fn read(
        buffer: []u8,
        stream: var,
    ) !Handshake {
        if (buffer.len < 68) return error.BufferTooSmall;
        var i: usize = 20;
        var self: Handshake = undefined;
        const size = try stream.readAll(buffer);

        const length = std.mem.readIntBig(u8, &buffer[0]);
        if (length == 0 or length > 19) return error.BadHandshake;

        self.p_str = buffer[1..length];
        std.mem.copy(u8, &self.hash, buffer[length + 9 .. length + 29]);
        std.mem.copy(u8, &self.peer, buffer[length + 29 .. length + 49]);

        return self;
    }
};

test "Serialize handshake" {
    const hs = Handshake.init(
        "12345678901234567890",
        "12345678901234567890",
    );

    const result = try hs.serialize(testing.allocator);
    defer testing.allocator.free(result);
    testing.expect(result.len == 68);
}

test "Deserialize handshake" {
    const hs = Handshake.init(
        "12345678901234567890",
        "12345678901234567890",
    );

    const data = try hs.serialize(testing.allocator);
    defer testing.allocator.free(data);
    const stream = std.io.fixedBufferStream(data).inStream();
    var buffer = try testing.allocator.alloc(u8, 100);
    defer testing.allocator.free(buffer);
    var result = try Handshake.read(buffer, stream);
    testing.expectEqualSlices(u8, "BitTorrent protocol", result.p_str);
}
