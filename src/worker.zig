const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const Allocator = std.mem.Allocator;
const Peer = @import("Peer.zig");
const Torrent = @import("Torrent.zig");
const Client = @import("net/Tcp_client.zig");
const Message = @import("net/message.zig").Message;

/// Max blocks we request at a time
const max_items = 5;
/// most clients/servers report this as max block size (2^14)
const max_block_size = 16384;

fn compare(a: Work, b: Work) bool {
    return true;
}

/// Worker that manages jobs
pub const Worker = struct {
    const Self = @This();
    /// mutex used to lock and unlock this `Worker` for multi-threading support
    mutex: *std.Thread.Mutex,
    /// Priority based queue that contains our pieces that need to be downloaded
    /// we probably want to replace this with a regular queue as the priority does not matter
    work: *std.ArrayList(Work),
    /// Constant Torrent reference, purely for access to its data
    torrent: *const Torrent,
    /// Remaining worker slots left based on peers
    workers: usize,
    /// allocator used for the workers to allocate and free memory
    gpa: *Allocator,
    /// the total size that has been downloaded so far
    downloaded: usize,
    /// The file we write to
    file: std.fs.File,

    /// Creates a new worker for the given work
    pub fn init(
        gpa: *Allocator,
        mutex: *std.Thread.Mutex,
        torrent: *const Torrent,
        work: *std.ArrayList(Work),
        file: std.fs.File,
    ) Self {
        return Self{
            .mutex = mutex,
            .work = work,
            .torrent = torrent,
            .workers = torrent.peers.len,
            .gpa = gpa,
            .file = file,
            .downloaded = 0,
        };
    }

    /// Returns a Client for a worker, returns null if all peers have a client.
    /// TODO, implement a way to get back client slots when a (unexpected) disconnect happends
    pub fn getClient(self: *Self) ?Client {
        const lock = self.mutex.acquire();
        defer lock.release();

        const peer = if (self.workers > 0) self.torrent.peers[self.workers - 1] else return null;
        var client = Client.init(peer, self.torrent.file.hash, self.torrent.peer_id);
        self.workers -= 1;

        return client;
    }

    /// Puts a new piece of work in the queue
    pub fn put(self: *Self, work: Work) !void {
        const lock = self.mutex.acquire();
        defer lock.release();
        try self.work.append(work);
    }

    /// Returns next job from queue, returns null if no work left.
    pub fn next(self: *Self) ?Work {
        const lock = self.mutex.acquire();
        defer lock.release();
        return self.work.popOrNull();
    }

    /// Writes a piece of work to a file. This blocks access to the Worker.
    /// This will also destroy the given `Work` piece.
    pub fn write(self: *Self, work: *Work) !void {
        const lock = self.mutex.acquire();
        defer lock.release();
        const size = try self.file.pwrite(work.buffer, work.index * work.size);
        self.downloaded += size;
        const completed: f64 = @intToFloat(f64, self.downloaded) / @intToFloat(f64, self.torrent.file.size) * 100;
        std.debug.print("\r{:.2} \t\t{:.2} \t\t {d:.2}", .{
            std.fmt.fmtIntSizeBin(self.downloaded),
            std.fmt.fmtIntSizeBin(self.torrent.file.size),
            completed,
        });
    }
};

/// A piece of work that needs to be downloaded
pub const Work = struct {
    const Self = @This();
    index: u32,
    hash: [20]u8,
    size: u32,
    gpa: *Allocator,
    buffer: []u8,

    /// Initializes work and creates a buffer according to the given size,
    /// call deinit() to free its memory.
    pub fn init(index: u32, hash: [20]u8, size: u32, gpa: *Allocator) Self {
        return Self{
            .index = index,
            .hash = hash,
            .size = size,
            .gpa = gpa,
            .buffer = undefined,
        };
    }

    /// Creates a buffer with the size of the work piece,
    /// then downloads the smaller pieces and puts them inside the buffer
    pub fn download(self: *Self, client: *Client) !void {
        var downloaded: usize = 0;
        var requested: u32 = 0;
        var backlog: usize = 0;
        // incase of an error, the thread function will take care of the memory
        self.buffer = try self.gpa.alloc(u8, self.size);

        // request to the peer for more bytes
        while (downloaded < self.size) {
            // if we are not choked, request for bytes
            if (!client.choked) {
                while (backlog < max_items and requested < self.size) : (backlog += 1) {
                    const block_size: u32 = if (self.size - requested < max_block_size) self.size - requested else max_block_size;
                    try client.sendRequest(self.index, requested, block_size);
                    requested += block_size;
                }
            }

            var message = Message.deserialize(self.gpa, client.socket.reader()) catch |err| switch (err) {
                error.Unsupported => continue, // Unsupported protocol message type/extension
                else => |e| return e,
            } orelse continue; // peer sent keep-alive
            defer message.deinit(self.gpa);

            switch (message) {
                .choke => client.choked = true,
                .unchoke => client.choked = false,
                .have => |index| if (client.bitfield) |*bit_field| bit_field.setPiece(index),
                .piece => |piece| {
                    downloaded += piece.block.len;
                    backlog -= 1;
                    std.mem.copy(u8, self.buffer[piece.begin..], piece.block);
                },
                .bitfield => |payload| client.bitfield = .{ .buffer = payload },
                else => {},
            }
        }
    }

    /// Frees the Work's memory
    pub fn deinit(self: *Self) void {
        self.gpa.free(self.buffer);
        self.* = undefined;
    }

    /// Checks the integrity of the data by checking its hash against the work's hash.
    pub fn eqlHash(self: Self) bool {
        var out: [20]u8 = undefined;
        Sha1.hash(self.buffer, &out, .{});
        return std.mem.eql(u8, &self.hash, &out);
    }
};
