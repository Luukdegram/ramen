const std = @import("std");
const meta = std.meta;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// All supported message types by the client
/// any others will be skipped
pub const Message = union(enum(u8)) {
    /// Whether or not the remote peer has choked this client.
    choke,
    /// The remote peer has unchoked the client.
    unchoke,
    /// Notifies the peer we are interested in more data.
    interested,
    /// Notifies the peer we are no longer interested in data.
    not_interested,
    /// Contains the index of a piece the peer has.
    have: u32,
    /// Only sent in the very first message. Sent to peer
    /// to tell which pieces have already been download.
    /// This is used to resume a download from a later point.
    bitfield: []const u8,
    /// Tells the peer the index, begin and length of the data we are requesting.
    request: Data,
    /// Tells the peer the index, begin and piece which the client wants to receive.
    piece: struct {
        index: u32,
        begin: u32,
        block: Block,
    },
    /// Used to notify all-but-one peer to cancel data requests as the last piece is being received.
    cancel: Data,

    /// Message types
    pub const Tag = meta.Tag(Message);

    /// `Block` is a slice of data, and is a subset of `Piece`.
    pub const Block = []const u8;

    /// `Data` specifies the index of the piece, the byte-offset within the piece
    /// and the length of the data to be requested/cancelled
    pub const Data = struct {
        index: u32,
        begin: u32,
        length: u32,
    };

    pub const DeserializeError = error{
        /// Peer has closed the connection
        EndOfStream,
        /// Peer has sent an unsupported message type
        /// such as notifying us of udp support.
        Unsupported,
        /// Machine is out of memory and no memory can be allocated
        /// on the heap.
        OutOfMemory,
    };

    fn toInt(self: Message) u8 {
        return @enumToInt(self);
    }

    /// Returns the serialization length of the given `Message`
    fn serializeLen(self: Message) u32 {
        return switch (self) {
            .choke,
            .unchoke,
            .interested,
            .not_interested,
            => 0,
            .have => 4,
            .bitfield => @panic("TODO: bitfield serializeLen"),
            .request, .cancel => 12,
            .piece => |piece| 12 + piece.block.len,
        };
    }

    /// Deinitializes the given `Message`.
    /// The `Allocator` is only needed for messages that have a variable size such as `Message.piece`.
    /// All other messages are a no-op.
    pub fn deinit(self: *Message, gpa: *Allocator) void {
        switch (self) {
            .piece => |piece| gpa.free(piece.block),
            else => {},
        }
        self.* = undefined;
    }

    /// Deserializes the current data into a `Message`. Uses the given `Allocator` when
    /// the payload is dynamic. All other messages will use a fixed-size buffer for speed.
    /// Returns `DeserializeError.Unsupported` when it tries to deserialize a message type that is
    /// not supported by the library yet.
    /// Returns `null` when peer has sent keep-alive
    pub fn deserialize(gpa: *Allocator, reader: anytype) (DeserializeError || @TypeOf(reader))!?Message {
        const length = try reader.readIntBig(u32);
        if (length == 0) return null;

        const type_byte = try reader.readByte();
        const message_type = meta.intToEnum(Tag, type_byte) catch return error.Unsupported;

        return switch (message_type) {
            .choke => Message.choke,
            .unchoke => Message.unchoke,
            .interested => Message.interested,
            .not_interested => Message.not_interested,
            .have => try deserializeHave(reader),
            .bitfield => try deserializeBitfield(gpa, length - 1, reader),
            .request => try deserializeRequest(.request, reader),
            .piece => try deserializePiece(gpa, length - 1, reader),
            .cancel => try deserializeData(.cancel, reader),
        };
    }

    /// Serializes the given `Message` and writes it to the given `writer`
    pub fn serialize(self: Message, writer: anytype) @TypeOf(writer)!void {
        const len = self.serializeLen() + 1; // 1 for the message type
        try writer.writeByte(len);
        try writer.writeByte(self.toInt());
        switch (self) {
            .choke,
            unchoke,
            interested,
            not_interested,
            => {},
            .have => |index| try writer.writeIntBig(index),
            .bitfield => @panic("TODO: Serialize bitfield"),
            .request, .cancel => |data| {
                try writer.writeIntBig(data.index);
                try writer.writeIntBig(data.begin);
                try writer.writeIntBig(data.length);
            },
            .piece => |piece| {
                try writer.writeIntBig(piece.index);
                try writer.writeIntBig(piece.begin);
                try writer.writeAll(piece.block);
            },
        }
    }

    /// Deserializes the given `reader` into a `Message.have`
    fn deserializeHave(reader: anytype) @TypeOf(reader).Error!Message {
        return Message{ .have = try reader.readIntBig(u32) };
    }

    /// Deserializes the given `reader` into a `Message.bitfield`
    /// As the length of the bitfield payload is variable, it requires an allocator
    fn deserializeBitfield(gpa: *Allocator, length: u32, reader: anytype) @TypeOf(reader).Error!Message {
        @panic("TODO: Implement deserializeBitfield");
    }

    /// Deserializes a fixed-length payload into a `Message.Request`
    fn deserializeData(kind: enum { request, cancel }, reader: anytype) @TypeOf(reader).Error!Message {
        const data: Data = .{
            .index = try reader.readIntBig(u32),
            .begin = try reader.readIntBig(u32),
            .length = try reader.readIntBig(u32),
        };
        return Message{switch (kind) {
            .request => .request = data,
            .cancel => .cancel = data,
        }};
    }

    /// Deserializes the current reader into `Message.piece`.
    /// As the length of the payload is variable, it accepts a length and `Allocator`.
    /// Note that it blocks on reading the payload until all is read.
    fn deserializePiece(gpa: *Allocator, length: u32, reader: anytype) (DeserializeError || @TypeOf(reader).Error)!Message {
        const block = try gpa.alloc(length);
        return Message{
            .piece = .{
                .index = try reader.readIntBig(u32),
                .begin = try reader.readIntBig(u32),
                .block = try reader.readAll(block),
            },
        };
    }
};
