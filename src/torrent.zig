const std = @import("std");
const testing = std.testing;
const http = @import("net/http.zig");

const local_port: u16 = 6881;

const Info = struct {
    pieces: []const u8,
    pieceLen: usize,
    size: usize,
    name: []const u8,
};

const Torrent = struct {
    announce: []const u8,
    info: *Info,

    pub fn decode() TorrentFile {}
};

const QueryParameter = struct {
    name: []const u8,
    value: []const u8,
};

/// TorrentFile represents the data structure needed to retreive all torrent data
const TorrentFile = struct {
    /// the URL to be called to retreive torrent data from
    announce: []const u8,
    /// hashed metadata of the torrent
    infoHash: []const u8,
    /// hashes of each individual piece to be downloaded, used to check and validate legitimacy
    pieceHashes: []const []const u8,
    /// the length of each piece
    pieceLen: usize,
    /// total size of the file
    size: u32,
    /// name of the torrent file
    name: []const u8,

    /// Generates the URL to retreive tracker information
    pub fn trackerURL(self: @This(), allocator: *std.mem.Allocator, peer: []const u8, port: u16) ![]const u8 {
        // build our query paramaters
        const portS = try intToSlice(allocator, port);
        defer allocator.free(portS);
        const size = try intToSlice(allocator, self.size);
        defer allocator.free(size);

        const queries = [_]QueryParameter{
            .{ .name = "info_hash", .value = self.infoHash },
            .{ .name = "peer_id", .value = peer },
            .{ .name = "port", .value = portS },
            .{ .name = "uploaded", .value = "0" },
            .{ .name = "downloaded", .value = "0" },
            .{ .name = "compact", .value = "1" },
            .{ .name = "left", .value = size },
        };

        return try encodeUrl(allocator, self.announce, queries[0..]);
    }

    fn download(self: @This(), allocator: *std.mem.Allocator, path: []const u8) !void {
        var peerID: [20]u8 = undefined;
        const appName = "RAMEN";
        std.mem.copy(peerID[0..], appName);
        try std.crypto.randomBytes(peerID[appName.len..]);

        const peers = try getPeers(allocator, peersID, local_port);
    }

    fn getPeers(self: @This(), allocator: *std.mem.Allocator, peerID: [20]u8, port: u16) ![]Peer {
        const url = try self.trackerURL(allocator, peerID, port);

        const resp = try http.get(allocator, url);
    }
};

/// encodes queries into a query string attached to the provided base
/// i.e. results example.com?parm=val where `base` is example.com
/// and `queries` is a HashMap with key "parm" and value "val".
fn encodeUrl(allocator: *std.mem.Allocator, base: []const u8, queries: []const QueryParameter) ![]const u8 {
    if (queries.len == 0) return base;

    // Predetermine the size needed for our buffer
    const size = blk: {
        var sum: usize = base.len;
        for (queries) |query| {
            sum += query.name.len + query.value.len + 2; // 2 for symbols & and =
        }
        break :blk sum;
    };

    // Allocate a buffer of our predetermined size
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);

    // fill the buffer with our base and ? symbol
    std.mem.copy(u8, buf, base);
    std.mem.copy(u8, buf[base.len..], "?");

    // fill the rest of the buffer with our query string
    var index: usize = base.len + 1;
    for (queries) |query| {
        // skip first '&' symbol
        if (index > base.len + 1) {
            std.mem.copy(u8, buf[index..], "&");
            index += 1;
        }
        std.mem.copy(u8, buf[index..], query.name);
        index += query.name.len;
        std.mem.copy(u8, buf[index..], "=");
        index += 1;
        std.mem.copy(u8, buf[index..], query.value);
        index += query.value.len;
    }

    return buf;
}

/// Will create a string from the given integer.
/// i.e. creates "1234" from 1234.
fn intToSlice(allocator: *std.mem.Allocator, val: usize) ![]const u8 {
    const buffer = try allocator.alloc(u8, 100);
    return buffer[0..std.fmt.formatIntBuf(buffer, val, 10, false, std.fmt.FormatOptions{})];
}

pub fn unMarshal(data: []u8) !Torrent {}

test "encode URL queries" {
    const queries = [_]QueryParameter{
        .{ .name = "key1", .value = "val1" },
        .{ .name = "key2", .value = "val2" },
    };
    const base = "test.com";

    const result = try encodeUrl(testing.allocator, base, queries[0..]);
    defer testing.allocator.free(result);

    std.debug.assert(std.mem.eql(u8, "test.com?key1=val1&key2=val2", result));
}

test "generating tracker URL" {
    const hash = "12345678901234567890";
    const tf = TorrentFile{
        .announce = "example.com",
        .infoHash = hash,
        .size = 120,
        .pieceHashes = &[_][]const u8{hash},
        .pieceLen = 1,
        .name = "test",
    };
    const url = try tf.trackerURL(testing.allocator, "1234", 80);
    defer testing.allocator.free(url);
    std.debug.assert(std.mem.eql(u8, "example.com?info_hash=12345678901234567890&peer_id=1234&port=80&uploaded=0&downloaded=0&compact=1&left=120", url));
}
