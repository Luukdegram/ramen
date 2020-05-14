const std = @import("std");
const msg = @import("message.zig");

const Peer = @import("../peer.zig").Peer;
const Handshake = @import("handshake.zig").Handshake;

/// Client represents a connection between a peer and us
pub const TcpClient = struct {
    const Self = @This();

    peer: Peer,
    bitfield: []const u8 = "",
    hash: [20]u8,
    id: [20]u8,
    allocator: *std.mem.Allocator,
    socket: ?std.fs.File = null,

    /// initiates a new Client
    pub fn init(
        allocator: *std.mem.allocator,
        peer: Peer,
        hash: [20]u8,
        peer_id: [20]u8,
    ) !Self {
        return .{
            .peer = peer,
            .hash = hash,
            .id = peer_id,
            .allocator = allocator,
        };
    }

    /// Creates a connection with the peer
    pub fn connect(self: *Self) !void {
        const socket = try std.net.tcpConnectToAddress(self.peer.address);
        errdefer socket.close();

        // initialize our handshake
        _ = try self.handshake();

        // receive the Bitfield so we can start sending messages (optional)
        bitfield = try self.getBitfield();
        self.bitfield = bitfield;
    }

    /// Reads bytes from the connection and deserializes it into a `Message` object.
    pub fn read(self: Self) !msg.Message {
        return msg.Message.read(self.socket.inStream());
    }

    /// Sends a 'Request' message to the peer
    pub fn sendRequest(
        self: Self,
        index: u32,
        begin: u32,
        length: u32,
    ) !void {
        const message = msg.Message.requestMessage(self.allocator, index, begin, length);
        defer self.allocator.free(request);
        const buffer = message.serialize(self.allocator);
        defer self.allocator.free(buffer);
        _ = try self.socket.write(buffer);
    }

    /// Sends the 'Interested' message to the peer.
    pub fn sendInterested(self: Self) !void {
        const message = msg.Message.init(msg.MessageType.Interested);
        var buffer = message.serialize(self.allocator);
        defer self.allocator.free(buffer);
        _ = try self.socket.write(buffer);
    }

    /// Sends the 'Not Interested' message to the peer.
    pub fn sendNotInterested(self: Self) !void {
        const message = msg.Message.init(msg.MessageType.NotInterested);
        const buffer = message.serialize(self.allocator);
        defer self.allocator.free(buffer);
        _ = try self.socket.write(buffer);
    }

    /// Sends the 'Unchoke' message to the peer.
    pub fn sendUnchoke(self: Self) !void {
        const message = msg.Message.init(msg.MessageType.Unchoke);
        const buffer = message.serialize(self.allocator);
        defer self.allocator.free(buffer);
        _ = try self.socket.write(buffer);
    }

    /// Sends the 'Have' message to the peer.
    pub fn sendHave(self: Self, index: u32) !void {
        const have = msg.Message.haveMessage(self.allocator, index);
        defer self.allocator.free(have);
        const buffer = have.serialize(self.allocator);
        defer self.allocator.free(buffer);
        _ = try self.socket.write(buffer);
    }

    /// Closes the connection
    pub fn close(self: Self) void {
        self.socket.close();
    }

    /// Initiates a handshake between the peer and us.
    fn handshake(self: Self) !Handshake {
        var hs = Handshake.init(self.hash, self.peer);

        _ = try self.socket.write(hs.serialize(self.allocator));

        const response = try Handshake.read(self.allocator, self.socket.inStream());

        if (!std.mem.eql(u8, self.hash, response.hash)) return error.IncorrectHash;

        return response;
    }

    /// Attempt to receive a bitfield from the peer.
    fn getBitfield(self: Self) ![]const u8 {
        const message = try msg.Message.read(self.allocator, self.socket.inStream());

        if (msg.message_type != message.MessageType.Bitfield) return error.UnexpectedMessageType;

        return message.payload;
    }
};