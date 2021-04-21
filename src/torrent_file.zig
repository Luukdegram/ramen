const std = @import("std");
const testing = std.testing;
const http = @import("net/http.zig");
const Peer = @import("Peer.zig");
const Allocator = std.mem.Allocator;
const Sha1 = std.crypto.hash.Sha1;

const bencode = @import("bencode.zig");
const Torrent = @import("torrent.zig").Torrent;

/// Our port we will seed from when we implement seeding
/// Default based on 'BEP 3': http://bittorrent.org/beps/bep_0003.html
const local_port: u16 = 6881;

/// sub struct, part of torrent bencode file
const Info = struct {
    /// Total length of the file in case of a single-file torrent.
    /// Null when the torrent is a multi-file torrent
    length: ?usize = null,
    /// In case of multi-file torrents, `files` will be non-null
    /// and includes a list of directories with each file size
    files: ?[]const struct {
        length: usize,
        path: []const []const u8,
    } = null,
    /// Name of the torrentfile
    name: []const u8,
    /// The length of each piece
    piece_length: usize,
    /// The individual pieces as one slice of bytes
    /// Totals to an amount multiple of 20. Where each 20 bytes equals to a SHA1 hash.
    pieces: []const u8,

    /// Generates a Sha1 hash of the info metadata.
    fn hash(self: Info, gpa: *Allocator) ![20]u8 {
        // create arraylist for writer with some initial capacity to reduce allocation count
        var list = std.ArrayList(u8).init(gpa);
        defer list.deinit();

        const serializer = bencode.serializer(list.writer());
        try serializer.serialize(self);

        // create sha1 hash of bencoded info
        var result: [20]u8 = undefined;
        Sha1.hash(list.items, &result, .{});
        return result;
    }

    /// Retrieves the hashes of each individual piece
    fn pieceHashes(self: Info, gpa: *Allocator) ![][20]u8 {
        const hashes = self.pieces.len / 20; // 20 bytes per hash
        const buffer = try gpa.alloc([20]u8, hashes);
        errdefer gpa.free(buffer);

        // copy each hash into an element
        var i: usize = 0;
        while (i < hashes) : (i += 1) {
            // copy pieces payload into each piece hash
            std.mem.copy(u8, &buffer[i], self.pieces[i * 20 .. (i + 1) * 20]);
        }
        return buffer;
    }
};

/// Bencode file for torrent information
const TorrentMeta = struct {
    /// Torrent announce url
    announce: []const u8,
    /// Information regarding the pieces and the actual information required
    /// to correctly request for data from peers
    info: Info,
};

/// Bencode file with tracker information
const Tracker = struct {
    failure_reason: ?[]const u8 = null,
    /// Defines how often trackers are refreshed by the host
    interval: ?usize = null,
    /// Slice of all peers that are seeding
    peers: ?[]const u8 = null,
};

/// struct to hold URL query information
const QueryParameter = struct {
    name: []const u8,
    value: []const u8,
};

/// TorrentFile represents the data structure needed to retreive all torrent data
pub const TorrentFile = struct {
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
    /// The arena state, used to free all memory allocated at once
    /// during the TorrentFile generation
    state: std.heap.ArenaAllocator.State,

    /// Generates the URL to retreive tracker information
    pub fn trackerURL(self: TorrentFile, gpa: *Allocator, peer_id: [20]u8, port: u16) ![]const u8 {
        // build our query paramaters
        var buf: [4]u8 = undefined;
        const port_slice = try std.fmt.bufPrint(&buf, "{d}", .{port});
        var buf2: [100]u8 = undefined;
        const size = try std.fmt.bufPrint(&buf2, "{d}", .{self.size});

        const queries = [_]QueryParameter{
            .{ .name = "info_hash", .value = &self.hash },
            .{ .name = "peer_id", .value = &peer_id },
            .{ .name = "port", .value = port_slice },
            .{ .name = "uploaded", .value = "0" },
            .{ .name = "downloaded", .value = "0" },
            .{ .name = "compact", .value = "1" },
            .{ .name = "left", .value = size },
            .{ .name = "key", .value = "test1241" },
        };

        return try encodeUrl(gpa, self.announce, &queries);
    }

    pub fn deinit(self: *TorrentFile, gpa: *Allocator) void {
        self.state.promote(gpa).deinit();
        self.* = undefined;
    }

    /// Downloads the actual content and saves it to the given path
    pub fn download(self: *TorrentFile, gpa: *Allocator, path: []const u8) !void {
        // build our peers to connect to
        const peer_id = try generatePeerId();
        const peers = try self.getPeers(gpa, peer_id, local_port);
        defer gpa.free(peers);

        const torrent = Torrent{
            .peers = peers,
            .peer_id = peer_id,
            .file = self,
        };

        // create destination file
        const full_path = try std.fs.path.join(gpa, &[_][]const u8{
            path,
            self.name,
        });
        defer gpa.free(full_path);

        // This is blocking and will actually download the contents of the torrent
        try torrent.download(gpa, full_path);
    }

    /// calls the trackerURL to retrieve a list of peers and our interval
    /// of when we can obtain a new list of peers.
    fn getPeers(self: TorrentFile, gpa: *Allocator, peer_id: [20]u8, port: u16) ![]const Peer {
        // apart from the slice of Peers we only allocate temporary data
        // therefore it's easier (and faster) to just use an arena here
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        const ally = &arena.allocator;

        const url = try self.trackerURL(ally, peer_id, port);

        const resp = try http.get(ally, url);

        if (!std.mem.eql(u8, resp.status_code, "200")) return error.CouldNotConnect;

        var stream = std.io.fixedBufferStream(resp.body);
        var deserializer = bencode.deserializer(ally, stream.reader());
        const tracker = try deserializer.deserialize(Tracker);

        if (tracker.failure_reason) |reason| {
            std.log.err("Could not connect with tracker: '{s}'", .{reason});
            return error.CouldNotConnect;
        }

        // the peers are compacted into binary format, so decode those too.
        return Peer.listFromCompact(gpa, tracker.peers.?);
    }

    /// Opens a torrentfile from the given path
    /// and decodes the Bencode into a `TorrentFile`
    pub fn open(gpa: *Allocator, path: []const u8) !TorrentFile {
        if (!std.mem.endsWith(u8, path, ".torrent")) return error.WrongFormat;

        // open the file
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        var arena = std.heap.ArenaAllocator.init(gpa);

        var deserializer = bencode.deserializer(&arena.allocator, file.reader());
        const meta = try deserializer.deserialize(TorrentMeta);

        const hash = try meta.info.hash(&arena.allocator);
        const piece_hashes = try meta.info.pieceHashes(&arena.allocator);

        const size = meta.info.length orelse blk: {
            var i: usize = 0;
            for (meta.info.files.?) |part| {
                i += part.length;
            }
            break :blk i;
        };

        return TorrentFile{
            .announce = meta.announce,
            .hash = hash,
            .piece_hashes = piece_hashes,
            .piece_length = meta.info.piece_length,
            .size = size,
            .name = meta.info.name,
            .state = arena.state,
        };
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
    std.crypto.random.bytes(&buf);
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
fn encodeUrl(gpa: *Allocator, base: []const u8, queries: []const QueryParameter) ![]const u8 {
    if (queries.len == 0) return base;

    var list = std.ArrayList(u8).init(gpa);
    defer list.deinit();

    const writer = list.writer();
    try writer.writeAll(base);
    try writer.writeByte('?');
    for (queries) |query, i| {
        if (i != 0) {
            try writer.writeByte('&');
        }
        try writer.writeAll(query.name);
        try writer.writeByte('=');
        try escapeSlice(writer, query.value);
        // try writer.writeAll(query.value);
    }

    return list.toOwnedSlice();
}

fn escapeSlice(writer: anytype, slice: []const u8) !void {
    for (slice) |c| try escapeChar(writer, c);
}

/// Encodes a singular character
fn escapeChar(writer: anytype, char: u8) !void {
    switch (char) {
        '0'...'9',
        'a'...'z',
        'A'...'Z',
        '.',
        '-',
        '_',
        '~',
        => try writer.writeByte(char),
        else => try writer.print("%{X:0>2}", .{char}),
    }
}

test "encode URL queries" {
    const queries = [_]QueryParameter{
        .{ .name = "key1", .value = "val1" },
        .{ .name = "key2", .value = "val2" },
    };
    const base = "test.com";

    const result = try encodeUrl(testing.allocator, base, &queries);
    defer testing.allocator.free(result);

    testing.expectEqualStrings("test.com?key1=val1&key2=val2", result);
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
        .state = undefined,
    };
    const url = try tf.trackerURL(
        testing.allocator,
        "12345678901234567890".*,
        80,
    );
    defer testing.allocator.free(url);
    testing.expectEqualStrings(
        "example.com?info_hash=12345678901234567890&peer_id=12345678901234567890&port=80&uploaded=0&downloaded=0&compact=1&left=120",
        url,
    );
}

test "Escape url" {
    const test_string = "https://www.google.com/search?q=tracker+info_hash+escape&oq=tracker+" ++
        "info_hash+escape&aqs=chrome..69i57j33i160l2.3049j0j7&sourceid=chrome&ie=UTF-8";
    const expected = "https%3A%2F%2Fwww.google.com%2Fsearch%3Fq%3Dtracker%2Binfo_hash%2B" ++
        "escape%26oq%3Dtracker%2Binfo_hash%2Bescape%26aqs%3Dchrome..69i57j33i160l2.3049j0j7%26sourceid%3Dchrome%26ie%3DUTF-8";

    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    try escapeSlice(list.writer(), test_string);
    testing.expectEqualStrings(expected, list.items);
}
