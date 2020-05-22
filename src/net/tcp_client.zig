const std = @import("std");
const msg = @import("message.zig");

const Peer = @import("../peer.zig").Peer;
const Handshake = @import("handshake.zig").Handshake;

/// Client represents a connection between a peer and us
pub const TcpClient = struct {
    const Self = @This();
    /// peer we are connected to
    peer: Peer,
    /// bit representation of the pieces we have
    bitfield: ?Bitfield = null,
    /// hash of meta info
    hash: [20]u8,
    /// unique id we represent ourselves with to our peer
    id: [20]u8,
    /// memory allocator
    allocator: *std.mem.Allocator,
    /// socket that handles our tcp connection and read/write from/to
    socket: std.fs.File,
    /// determines if we are choked by the peer, this is true by default
    choked: bool = true,

    /// initiates a new Client, to connect call connect()
    pub fn init(
        allocator: *std.mem.Allocator,
        peer: Peer,
        hash: [20]u8,
        peer_id: [20]u8,
    ) Self {
        return .{
            .peer = peer,
            .hash = hash,
            .id = peer_id,
            .allocator = allocator,
            .socket = undefined,
            .bitfield = undefined,
        };
    }

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

    /// Creates a connection with the peer,
    /// this fails if we cannot receive a proper handshake
    pub fn connect(self: *Self) !void {
        var socket = try std.net.tcpConnectToAddress(self.peer.address);
        self.socket = socket;
        errdefer socket.close();

        // initialize our handshake
        _ = try self.handshake();

        //receive the Bitfield so we can start sending messages
        if (try self.getBitfield()) |bitfield| {
            self.bitfield = Bitfield{ .buffer = bitfield };
        }
    }

    /// Reads bytes from the connection and deserializes it into a `Message` object.
    /// This function allocates memory that must be freed.
    /// If null returned, it's a keep-alive message.
    pub fn read(self: Self) !?msg.Message {
        return msg.Message.read(self.allocator, self.socket.inStream());
    }

    /// Sends a 'Request' message to the peer
    pub fn sendRequest(
        self: Self,
        index: usize,
        begin: usize,
        length: usize,
    ) !void {
        const allocator = self.allocator;
        const message = try msg.Message.requestMessage(allocator, index, begin, length);
        defer allocator.free(message.payload);
        const buffer = try message.serialize(allocator);
        defer allocator.free(buffer);
        _ = try self.socket.write(buffer);
    }

    /// Sends a message of the given `MessageType` to the peer.
    pub fn send(self: Self, message_type: msg.MessageType) !void {
        const message = msg.Message.init(message_type);
        const buffer = try message.serialize(self.allocator);
        defer self.allocator.free(buffer);
        _ = try self.socket.write(buffer);
    }

    /// Sends the 'Have' message to the peer.
    pub fn sendHave(self: Self, index: usize) !void {
        const allocator = self.allocator;
        const have = try msg.Message.haveMessage(allocator, index);
        defer allocator.free(have.payload);
        const buffer = try have.serialize(allocator);
        defer allocator.free(buffer);
        _ = try self.socket.write(buffer);
    }

    /// Closes the connection
    pub fn close(self: *Self) void {
        self.socket.close();
        self.allocator.free(self.peer.ip);
        self.allocator.free(self.bitfield.?.buffer);
        self.* = undefined;
    }

    /// Initiates a handshake between the peer and us.
    fn handshake(self: Self) !Handshake {
        var hs = Handshake.init(self.hash, self.id);

        _ = try self.socket.write(try hs.serialize(self.allocator));

        // handshake is a fixed-size message and requires to be 68 bytes long.
        var tmp = try self.allocator.alloc(u8, 68);
        defer self.allocator.free(tmp);
        const response = try Handshake.read(tmp, self.socket.inStream());

        if (!std.mem.eql(u8, &self.hash, &response.hash)) return error.IncorrectHash;

        return response;
    }

    /// Attempt to receive a bitfield from the peer.
    fn getBitfield(self: Self) !?[]u8 {
        if (try msg.Message.read(self.allocator, self.socket.inStream())) |message| {
            if (message.message_type != msg.MessageType.Bitfield) return error.UnexpectedMessageType;
            return message.payload;
        } else {
            return null;
        }
    }
};
