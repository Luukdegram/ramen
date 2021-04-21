const std = @import("std");
const testing = std.testing;

const Handshake = @This();

hash: [20]u8,
peer_id: [20]u8,

const p_str = "BitTorrent protocol";
const p_strlen = @intCast(u8, p_str.len);

/// Serializes a Handshake object into binary data and writes the result to the writer
pub fn serialize(self: Handshake, writer: anytype) @TypeOf(writer).Error!void {
    // we first copy everything into a buffer to avoid syscalls as
    // the length of the buffer is fixed-length
    var buffer: [p_strlen + 49]u8 = undefined;
    buffer[0] = p_strlen;
    std.mem.copy(u8, buffer[1..], p_str);
    const index = p_strlen + 8 + 1; // 8 reserved bytes
    std.mem.copy(u8, buffer[index..], &self.hash);
    std.mem.copy(u8, buffer[index + 20 ..], &self.peer_id);
    try writer.writeAll(&buffer);
}

pub const DeserializeError = error{
    /// Connection was closed by peer
    EndOfStream,
    /// Peer's p_strlen is invalid
    BadHandshake,
};

/// Deserializes from an `io.Reader` and parses the binary data into a `Handshake`
pub fn deserialize(
    reader: anytype,
) (DeserializeError || @TypeOf(reader).Error)!Handshake {
    var buffer: [p_strlen + 49]u8 = undefined;
    try reader.readNoEof(&buffer);

    const length = std.mem.readIntBig(u8, &buffer[0]);
    if (length != 19) return error.BadHandshake; // Peer's p_strlen is invalid

    return Handshake{
        .hash = buffer[length + 9 ..][0..20].*,
        .peer_id = buffer[length + 29 ..][0..20].*,
    };
}

test "Serialize handshake" {
    var hash = [_]u8{0} ** 20;
    var peer_id = [_]u8{0} ** 20;
    const hs: Handshake = .{
        .hash = hash,
        .peer_id = peer_id,
    };

    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    try hs.serialize(list.writer());
    testing.expect(list.items.len == 68);
}

test "Deserialize handshake" {
    var hash = [_]u8{'a'} ** 20;
    var peer_id = [_]u8{'a'} ** 20;
    const hand_shake: Handshake = .{
        .hash = hash,
        .peer_id = peer_id,
    };

    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();
    try hand_shake.serialize(list.writer());

    const reader = std.io.fixedBufferStream(list.items).reader();
    const result = try Handshake.deserialize(reader);
    testing.expectEqualSlices(u8, "BitTorrent protocol", p_str);
    testing.expectEqualSlices(u8, &hand_shake.hash, &result.hash);
    testing.expectEqualSlices(u8, &hand_shake.peer_id, &result.peer_id);
}
