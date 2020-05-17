const std = @import("std");
const Sha1 = std.crypto.Sha1;
const Allocator = std.mem.Allocator;
const Peer = @import("peer.zig").Peer;
const Torrent = @import("torrent.zig").Torrent;
const Client = @import("net/tcp_client.zig").TcpClient;

/// Context passed to the working threads
pub const WorkerContext = struct {
    worker: *Worker,
};

/// Worker that manages jobs
pub const Worker = struct {
    const Self = @This();
    mutex: *std.Mutex,
    work: *std.PriorityQueue(Work),
    torrent: *const Torrent,
    workers: usize,
    allocator: *Allocator,

    /// Creates a new worker for the given work
    pub fn init(
        allocator: *Allocator,
        mutex: *std.Mutex,
        torrent: *const Torrent,
        work: []Work,
    ) Self {
        return Self{
            .mutex = mutex,
            .work = &std.PriorityQueue(Work).fromOwnedSlice(allocator, compare, work),
            .torrent = torrent,
            .workers = torrent.peers.len,
            .allocator = allocator,
        };
    }

    /// Returns a Client for a worker, returns null if no empty spots are left.
    pub fn getClient(self: *Self) ?Client {
        const lock = self.mutex.acquire();
        defer lock.release();

        const peer = if (self.workers > 0) self.torrent.peers[self.workers - 1] else return null;
        var client = Client.init(self.allocator, peer, self.torrent.file.hash, self.torrent.peer_id);
        self.workers -= 1;

        return client;
    }

    /// Returns next job from queue, returns null if no work left.
    pub fn next(self: *Self) ?Work {
        const lock = self.mutex.acquire();
        defer lock.release();
        return self.work.*.removeOrNull();
    }
};

/// determines the position in the queue
fn compare(a: Work, b: Work) bool {
    return a.index < b.index;
}

/// A piece of work that needs to be done
pub const Work = struct {
    index: usize,
    hash: [20]u8,
    size: usize,

    /// Checks the integrity of the data by checking its hash against the work's hash.
    fn eqlHash(self: @This(), buffer: []const u8) bool {
        var out: [20]u8 = undefined;
        Sha1.hash(buffer, &out);
        return std.mem.eql(u8, &self.hash, &out);
    }
};
