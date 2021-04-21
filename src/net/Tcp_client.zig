const std = @import("std");
const Allocator = std.mem.Allocator;

const Peer = @import("../Peer.zig");
const Handshake = @import("Handshake.zig");
const Message = @import("message.zig").Message;

const TcpClient = @This();

/// peer we are connected to
peer: Peer,
/// bit representation of the pieces we have
bitfield: ?Bitfield,
/// hash of meta info
hash: [20]u8,
/// unique id we represent ourselves with to our peer
id: [20]u8,
/// socket that handles our tcp connection and read/write from/to
socket: std.net.Stream,
/// determines if we are choked by the peer, this is true by default
choked: bool = true,

/// Bitfield represents a slice of bits that represents the pieces
/// that have already been downloaded. The struct contains helper methods
/// to check and set pieces.
const Bitfield = struct {
    buffer: []u8,

    /// hasPiece checks if the specified index contains a bit of 1
    pub fn hasPiece(self: Bitfield, index: usize) bool {
        var buffer = self.buffer;
        const byte_index = index / 8;
        const offset = index % 8;
        if (byte_index < 0 or byte_index > buffer.len) return false;

        return buffer[byte_index] >> (7 - @intCast(u3, offset)) & 1 != 0;
    }

    /// Sets a bit inside the bitfield to 1
    pub fn setPiece(self: *Bitfield, index: usize) void {
        //var buffer = self.buffer;
        const byte_index = index / 8;
        const offset = index % 8;

        // if out of bounds, simply don't write the bit
        if (byte_index >= 0 and byte_index < self.buffer.len) {
            self.buffer[byte_index] |= @as(u8, 1) << (7 - @intCast(u3, offset));
        }
    }
};

/// initiates a new Client, to connect call connect()
pub fn init(peer: Peer, hash: [20]u8, peer_id: [20]u8) TcpClient {
    return .{
        .peer = peer,
        .hash = hash,
        .id = peer_id,
        .socket = undefined,
        .bitfield = null,
    };
}

/// Creates a connection with the peer,
/// this fails if we cannot receive a proper handshake
pub fn connect(self: *TcpClient) !void {
    self.socket = try std.net.tcpConnectToAddress(self.peer.address);
    errdefer self.socket.close();

    // initialize our handshake
    try self.validateHandshake();
}

/// Sends a 'Request' message to the peer
pub fn sendRequest(self: TcpClient, index: u32, begin: u32, length: u32) !void {
    try (Message{ .request = .{
        .index = index,
        .begin = begin,
        .length = length,
    } }).serialize(self.socket.writer());
}

/// Sends a message to the peer.
pub fn send(self: TcpClient, message: Message) !void {
    try message.serialize(self.socket.writer());
}

/// Sends the 'Have' message to the peer indicating we have the piece
/// at given 'index'.
pub fn sendHave(self: TcpClient, index: u32) !void {
    try (Message{ .have = index }).serialize(self.socket.writer());
}

/// Closes the connection and frees any memory that has been allocated
/// Use after calling `close()` is illegal behaviour.
pub fn close(self: *TcpClient, gpa: *Allocator) void {
    self.socket.close();
    if (self.bitfield) |bit_field| {
        gpa.free(bit_field.buffer);
    }
    self.* = undefined;
}

/// Initiates and validates the handshake with the peer
/// This must be called first before sending anything else, calling it twice is illegal.
fn validateHandshake(self: TcpClient) !void {
    const hand_shake: Handshake = .{
        .hash = self.hash,
        .peer_id = self.id,
    };

    try hand_shake.serialize(self.socket.writer());
    const result = try Handshake.deserialize(self.socket.reader());

    if (!std.mem.eql(u8, &self.hash, &result.hash)) return error.IncorrectHash;
}
