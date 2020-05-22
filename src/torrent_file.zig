const std = @import("std");
const testing = std.testing;
const http = @import("net/http.zig");
const peer = @import("peer.zig");

const Bencode = @import("bencode.zig").Bencode;
const Torrent = @import("torrent.zig").Torrent;

/// Our port we will seed from when we implement seeding
/// Default based on 'BEP 3': http://bittorrent.org/beps/bep_0003.html
const local_port: u16 = 6881;

// sub struct, part of torrent bencode file
const Info = struct {
    length: usize,
    name: []const u8,
    piece_length: usize,
    pieces: []const u8,

    /// Generates a Sha1 hash of the info metadata.
    fn hash(self: @This(), allocator: *std.mem.Allocator) ![20]u8 {
        // allocate enough memory for buffer
        const size = self.pieces.len + self.name.len + 100;
        var buffer = try allocator.alloc(u8, size);
        errdefer allocator.free(buffer);

        // encode to Bencode
        var bencode = Bencode.init(allocator);
        const length = try bencode.marshal(Info, self, buffer);

        // create sha1 hash of bencoded info
        var result: [20]u8 = undefined;
        std.crypto.Sha1.hash(buffer[0..length], &result);
        return result;
    }

    /// Retrieves the hashes of each individual piece
    fn pieceHashes(self: @This(), allocator: *std.mem.Allocator) ![][20]u8 {
        const hashes = self.pieces.len / 20; // 20 bytes per hash
        var buffer = try allocator.alloc([20]u8, hashes);
        errdefer allocator.free(buffer);

        // copy each hash into an element
        var i: usize = 0;
        while (i < hashes) : (i += 1) {
            // copy pieces payload into each piece hash
            std.mem.copy(u8, &buffer[i], self.pieces[i * 20 .. (i + 1) * 20]);
        }
        return buffer;
    }
};

// Bencode file for torrent information
const TorrentMeta = struct {
    announce: []const u8,
    comment: []const u8,
    creation_date: usize,
    httpseeds: []const []const u8,
    info: Info,

    /// creates a new `TorrentFile` from our bencode information
    /// This also generates the hashes for each piece and the torrent info
    pub fn file(self: @This(), allocator: *std.mem.Allocator) !TorrentFile {
        const info = self.info;
        var hash: [20]u8 = undefined;
        hash = try info.hash(allocator);
        const piece_hashes = try info.pieceHashes(allocator);

        return TorrentFile{
            .announce = self.announce,
            .hash = hash,
            .piece_hashes = piece_hashes,
            .piece_length = info.piece_length,
            .size = info.length,
            .name = info.name,
            .allocator = allocator,
            // leave buffer undefined as its set in the callee's function
            .buffer = undefined,
        };
    }
};

// Bencode file with tracker information
const Tracker = struct {
    interval: usize,
    peers: []const u8,
};

// struct to hold URL query information
const QueryParameter = struct {
    name: []const u8,
    value: []const u8,
};

/// TorrentFile represents the data structure needed to retreive all torrent data
pub const TorrentFile = struct {
    const Self = @This();
    /// the URL to be called to retreive torrent data from
    announce: []const u8,
    /// hashed metadata of the torrent
    hash: [20]u8,
    /// hashes of each individual piece to be downloaded, used to check and validate legitimacy
    piece_hashes: []const [20]u8,
    /// the length of each piece
    piece_length: usize,
    /// total size of the file
    size: usize,
    /// name of the torrent file
    name: []const u8,
    /// allocator to allocate and free objects memory
    allocator: *std.mem.Allocator,
    /// buffer contains the struct itself and is used to free the memory of itself
    buffer: []const u8,

    /// Generates the URL to retreive tracker information
    pub fn trackerURL(self: Self, allocator: *std.mem.Allocator, peer_id: [20]u8, port: u16) ![]const u8 {
        // build our query paramaters
        const port_slice = try intToSlice(allocator, port);
        defer allocator.free(port_slice);
        const size = try intToSlice(allocator, self.size);
        defer allocator.free(size);

        const queries = [_]QueryParameter{
            .{ .name = "info_hash", .value = &self.hash },
            .{ .name = "peer_id", .value = &peer_id },
            .{ .name = "port", .value = port_slice },
            .{ .name = "uploaded", .value = "0" },
            .{ .name = "downloaded", .value = "0" },
            .{ .name = "compact", .value = "1" },
            .{ .name = "left", .value = size },
        };

        return try encodeUrl(allocator, self.announce, queries[0..]);
    }

    pub fn deinit(self: Self) void {
        self.allocator.free(self.piece_hashes);
        self.allocator.free(self.buffer);
    }

    /// Downloads the actual content and saves it to the given path
    pub fn download(self: *Self, path: []const u8) !void {
        // build our peers to connect to
        const peer_id = try generatePeerId();
        const peers = try self.getPeers(peer_id, local_port);

        const torrent = Torrent{
            .peers = peers,
            .peer_id = peer_id,
            .file = self,
        };

        // create destination file
        const full_path = try std.fs.path.join(self.allocator, &[_][]const u8{
            path,
            self.name,
        });

        defer self.allocator.free(full_path);
        const cwd = std.fs.cwd();
        var file = try cwd.createFile(full_path, .{ .lock = .Exclusive });
        defer file.close();

        // This is blocking
        try torrent.download(self.allocator, &file);
    }

    /// calls the trackerURL to retrieve a list of peers and our interval
    /// of when we can obtain a new list of peers.
    fn getPeers(self: Self, peer_id: [20]u8, port: u16) ![]peer.Peer {
        const allocator = self.allocator;
        const url = try self.trackerURL(allocator, peer_id, port);

        const resp = try http.get(allocator, url);

        if (!std.mem.eql(u8, resp.status_code, "200")) return error.CouldNotConnect;

        // the response is in bencode format, therefore decode it first
        var bencode = try Bencode.init(allocator).unmarshal(Tracker, resp.body);

        // the peers are in binary format, so unmarshal those too.
        return peer.unmarshal(allocator, bencode.peers);
    }

    /// Opens a torrentfile from the given path
    /// and decodes the Bencode into a `TorrentFile`
    pub fn open(allocator: *std.mem.Allocator, path: []const u8) !Self {
        if (!std.mem.endsWith(u8, path, ".torrent")) return error.WrongFormat;

        // open the file
        const cwd = std.fs.cwd();
        const file = try cwd.openFile(path, .{});
        defer file.close();
        const stat = try file.stat();
        var buffer = try allocator.alloc(u8, stat.size);
        _ = try file.inStream().readAll(buffer);

        // decode the bencode to retrieve our `Torrent` struct
        var bencode = Bencode.init(allocator);
        const torrent = try bencode.unmarshal(TorrentMeta, buffer);
        errdefer allocator.free(buffer);
        //TODO Remove this when we implement http seeds. For now free its memory to silence errors
        allocator.free(torrent.httpseeds);

        var torrent_file = try torrent.file(allocator);
        torrent_file.buffer = buffer;
        return torrent_file;
    }
};

/// generates a *new* peer_id, everytime this gets called.
fn generatePeerId() ![20]u8 {
    // full peer_id
    var peer_id: [20]u8 = undefined;
    // our app name which will always remain the same
    const app_name = "-RM0010-";
    std.mem.copy(u8, &peer_id, app_name);

    // generate a random seed
    var buf: [8]u8 = undefined;
    try std.crypto.randomBytes(&buf);
    const seed = std.mem.readIntLittle(u64, &buf);

    const lookup = "0123456789abcdefghijklmnopqrstuvwxyz";

    // generate next bytes
    var bytes: [12]u8 = undefined;
    var r = std.rand.DefaultPrng.init(seed);
    for (peer_id[app_name.len..]) |*b| {
        b.* = lookup[r.random.intRangeAtMost(u8, 0, lookup.len - 1)];
    }

    return peer_id;
}

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
    var hash: [20]u8 = undefined;
    std.mem.copy(u8, &hash, "12345678901234567890");
    var piece_hashes: [1][20]u8 = undefined;
    std.mem.copy(u8, &piece_hashes[0], &hash);
    const tf = TorrentFile{
        .announce = "example.com",
        .hash = hash,
        .size = 120,
        .piece_hashes = &piece_hashes,
        .piece_length = 1,
        .name = "test",
        .allocator = undefined,
        .buffer = undefined,
    };
    const url = try tf.trackerURL(testing.allocator, "1234", 80);
    defer testing.allocator.free(url);
    std.debug.assert(std.mem.eql(u8, "example.com?info_hash=12345678901234567890&peer_id=1234&port=80&uploaded=0&downloaded=0&compact=1&left=120", url));
}

test "read torrent file" {
    var path = "debian-10.4.0-arm64-netinst.iso.torrent";
    const torrent_file = try TorrentFile.open(testing.allocator, path);
    defer torrent_file.deinit();
    std.debug.warn("\nTorrent name: {}", .{torrent_file.hash});
    std.debug.warn("\nTorrent name: {}", .{torrent_file.hash});
}
