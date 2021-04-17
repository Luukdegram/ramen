const std = @import("std");
const testing = std.testing;

const Handshake = @This();

hash: [20]u8,
peer_id: [20]u8,

const p_str = "BitTorrent protocol";
const p_strlen = @intCast(u8, p_str.len);

/// Serializes a Handshake object into binary data
/// TODO: Should we accept a writer?
pub fn serialize(self: Handshake) []const u8 {
    var buffer: [p_strlen + 49]u8 = undefined;
    buffer[0] = @intCast(u8, p_strlen);
    std.mem.copy(u8, buffer[1..], self.p_str);
    const index = p_strlen + 8 + 1; // 8 reserved bytes
    std.mem.copy(u8, buffer[index..], &self.hash);
    std.mem.copy(u8, buffer[index + 20 ..], &self.peer);
    return &buffer;
}

pub const DeserializeError = error{
    /// Connection was closed by peer
    EndOfStream,
    /// Peer's p_strlen is invalid
    BadHandshake,
};

/// Deserializes from an `io.Reader` and parses the binary data into a `Handshake`
/// Asserts `buffer` has a 'len' of atleast p_strlen + 49 bytes
pub fn deserialize(
    buffer: []u8,
    reader: anytype,
) (DeserializeError || @TypeOf(reader).Error)!Handshake {
    std.debug.assert(buffer.len >= p_strlen + 49);
    const size = try stream.read(buffer);
    if (size == 0) return error.EndOfStream;

    const length = std.mem.readIntBig(u8, &buffer[0]);
    if (length != 19) return error.BadHandshake;

    return Handshake{
        .hash = buffer[length + 9 .. length + 29],
        .peer_id = buffer[length + 29 .. length + 49],
    };
}

test "Serialize handshake" {
    var hash = [_]u8{0} ** 20;
    var peer_id = [_]u8{0} ** 20;
    const hs = Handshake.init(
        hash,
        peer_id,
    );

    const result = try hs.serialize(testing.allocator);
    defer testing.allocator.free(result);
    testing.expect(result.len == 68);
}

test "Deserialize handshake" {
    var hash = [_]u8{'a'} ** 20;
    var peer_id = [_]u8{'a'} ** 20;
    const hs = Handshake.init(
        hash,
        peer_id,
    );

    const data = try hs.serialize(testing.allocator);
    defer testing.allocator.free(data);
    const stream = std.io.fixedBufferStream(data).inStream();
    var buffer = try testing.allocator.alloc(u8, 68);
    defer testing.allocator.free(buffer);
    var result = try Handshake.read(buffer, stream);
    testing.expectEqualSlices(u8, "BitTorrent protocol", result.p_str);
}
