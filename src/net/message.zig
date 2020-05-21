const std = @import("std");

/// Reserved message IDs
/// Currently, they only contain the Core Protocol IDs
pub const MessageType = enum(u8) {
    Choke,
    Unchoke,
    Interested,
    NotInterested,
    Have,
    Bitfield,
    Request,
    Piece,
    Cancel,
    _,
};

/// Messages are sent and received between us and the peer
/// Based on the message type we receive, we handle accordingly.
pub const Message = struct {
    const Self = @This();

    message_type: MessageType,
    payload: []u8,

    /// Creates an empty message of the given type.
    pub fn init(message_type: MessageType) Self {
        return .{ .message_type = message_type, .payload = "" };
    }

    /// Parses the payload of a `MessageType.Piece` into the given buffer
    /// returns the length of payload's data.
    pub fn parsePiece(
        self: Self,
        buffer: []u8,
        index: usize,
    ) !usize {
        if (self.message_type != .Piece) return error.IncorrectMessageType;

        if (self.payload.len < 8) return error.IncorrectPayload;

        const p_index = std.mem.readIntBig(u32, self.payload[0..4]);
        if (p_index != @intCast(u32, index)) {
            std.debug.warn("Incorrect index: {} - {}\n", .{ p_index, index });
            return error.IncorrectIndex;
        }

        const begin = std.mem.readIntBig(u32, self.payload[4..8]);
        if (begin > buffer.len) return error.IncorrectOffset;

        const data = self.payload[8..];
        if (begin + data.len > buffer.len) return error.OutOfMemory;
        std.mem.copy(u8, buffer[begin .. begin + data.len], data);
        return data.len;
    }

    /// Parses current `MessageType.Have` message and returns the index.
    pub fn parseHave(self: Self) !usize {
        if (self.message_type != .Have) return error.IncorrectMessageType;

        if (self.payload.len != 4) return error.IncorrectLength;

        return std.mem.readIntBig(u32, self.payload[0..4]);
    }

    /// Reads from an `io.Instream` and parses its content into a Message.
    pub fn read(
        allocator: *std.mem.Allocator,
        stream: std.io.InStream(
            std.fs.File,
            std.os.ReadError,
            std.fs.File.read,
        ),
    ) !?Self {
        var buffer = try allocator.alloc(u8, 4);
        defer allocator.free(buffer);

        const read_len = try stream.readAll(buffer);

        const length = std.mem.readIntBig(u32, buffer[0..4]);
        if (length == 0) return null; // keep-alive
        var payload = try allocator.alloc(u8, length);
        errdefer allocator.free(payload);
        const payload_size = try stream.readAll(payload);

        return Self{ .message_type = @intToEnum(MessageType, payload[0]), .payload = payload[1..] };
    }

    /// Serializes a message into the given buffer with the following format
    /// <length><message_type><payload>
    pub fn serialize(self: Self, allocator: *std.mem.Allocator) ![]const u8 {
        const length: u32 = @intCast(u32, self.payload.len) + 1; // type's length is 1 byte
        var buffer = try allocator.alloc(u8, length + 4); // 4 for length

        std.mem.writeIntBig(u32, buffer[0..4], length);
        buffer[4] = @enumToInt(self.message_type);
        std.mem.copy(u8, buffer[5..], self.payload);

        return buffer;
    }

    /// Creates a `Message` with the type Request
    pub fn requestMessage(
        allocator: *std.mem.Allocator,
        index: usize,
        begin: usize,
        length: usize,
    ) !Self {
        var buffer = try allocator.alloc(u8, 12);

        std.mem.writeIntBig(u32, buffer[0..4], @intCast(u32, index));
        std.mem.writeIntBig(u32, buffer[4..8], @intCast(u32, begin));
        std.mem.writeIntBig(u32, buffer[8..12], @intCast(u32, length));

        return Self{ .message_type = .Request, .payload = buffer };
    }

    /// Creates a `Message` with the type Have
    pub fn haveMessage(allocator: *std.mem.Allocator, index: usize) !Self {
        var buffer = try allocator.alloc(u8, 4);

        std.mem.writeIntBig(u32, buffer[0..4], @intCast(u32, index));

        return Self{ .message_type = .Have, .payload = buffer };
    }
};
