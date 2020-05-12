const std = import("std");

/// Message Types for the event loop
const MessageType = enum {
    Choke,
    Unchoke,
    Interested,
    NotInterested,
    Have,
    Bitfield,
    Request,
    Piece,
    Cancel,
};

/// Messages are sent and received between us and the peer
/// Based on the message type we receive, we handle accordingly.
pub const Message = struct {
    const Self = @This();

    message_type: MessageType,
    payload: []const u8,

    /// Parses the payload of a `MessageType.Piece` into the given buffer
    /// returns the length of payload's data.
    pub fn parsePiece(
        self: Self,
        buffer: []u8,
        index: u32,
    ) !usize {
        if (self.message_type != .Piece) return error.IncorrectMessageType;

        if (self.payload.len < 8) return error.IncorrectPayload;

        const p_index = std.mem.readIntSliceBig(u32, self.payload[0..4]);
        if (p_index != index) return error.IncorrectIndex;

        const begin = std.mem.readIntSliceBig(u32, self.payload[4..8]);
        if (begin > buffer.len) return error.IncorrectOffset;

        const data = self.payload[8..];
        if (data.len > buffer.len) return error.OutOfMemory;

        std.mem.copy(buffer[begin..], data);
        return data.len;
    }

    /// Parses current `MessageType.Have` message and returns the length
    pub fn parseHave(self: Self) !usize {
        if (self.message_type != .Have) return error.IncorrectMessageType;

        if (self.payload.len != 4) return error.IncorrectLength;

        return std.mem.readIntSliceBig(u32, self.payload);
    }

    /// Serializes a message into the given buffer with the following format
    /// <length><message_type><payload>
    pub fn serialize(self: Self, buffer: []u8) !void {
        const length = self.payload.len + 1; // type's length is 1 byte
        if (buffer.len < length + 4) return error.OutOfMemory; // 4 bytes for length
        std.mem.writeIntBig(u32, &buffer[0..4], length);
        std.mem.writeIntBig(u8, &buffer[5], @enumToInt(self.message_type));
        std.mem.copy(u8, buffer[5..], self.payload);
    }

    /// Creates a `Message` with the type Request
    pub fn requestMessage(
        buffer: []u8,
        index: u32,
        begin: u32,
        length: u32,
    ) !Self {
        if (buffer.len < 12) return error.OutOfMemory;

        std.mem.writeIntBig(u32, &buffer[0..4], index);
        std.mem.writeIntBig(u32, &buffer[4..8], begin);
        std.mem.writeIntBig(u32, &buffer[8..], length);

        return .{ .message_type = .Request, .payload = buffer };
    }

    /// Creates a `Message` with the type Have
    pub fn haveMessage(buffer: []u8, index: u32) !Self {
        if (buffer.len < 4) return error.OutOfMemory;

        std.mem.writeIntBig(u32, &buffer, index);

        return .{ .message_type = .Have, .payload = buffer };
    }
};
