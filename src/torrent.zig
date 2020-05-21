const std = @import("std");

const Peer = @import("peer.zig").Peer;
const TorrentFile = @import("torrent_file.zig").TorrentFile;
const Worker = @import("worker.zig").Worker;
const Work = @import("worker.zig").Work;
const WorkerContext = @import("worker.zig").WorkerContext;
const MessageType = @import("net/message.zig").MessageType;
const Client = @import("net/tcp_client.zig").TcpClient;

/// determines the position in the queue
fn compare(a: Work, b: Work) bool {
    return a.index < b.index;
}

pub const Torrent = struct {
    const Self = @This();
    // peers is a list of seeders we can connect to
    peers: []Peer,
    // unique idee to identify ourselves to others
    peer_id: [20]u8,
    // the corresponding torrent file that contains its meta data.
    file: *TorrentFile,

    /// Downloads the torrent and writes to the given stream
    pub fn download(
        self: Self,
        allocator: *std.mem.Allocator,
        file: *std.fs.File,
    ) !void {
        std.debug.warn("Download started for torrent: {}\n", .{self.file.name});

        var queue = std.PriorityQueue(Work).init(allocator, compare);
        var finished_queue = std.PriorityQueue(Work).init(allocator, compare);
        defer queue.deinit();
        defer finished_queue.deinit();

        // Creates jobs for all pieces that needs to be downloaded
        for (self.file.piece_hashes) |hash, i| {
            var work = Work.init(i, hash, self.pieceSize(i), allocator);
            try queue.add(work);
        }

        var mutex = std.Mutex.init();
        defer mutex.deinit();

        var worker = Worker.init(allocator, &mutex, &self, &queue, &finished_queue);

        var context = WorkerContext{
            .worker = &worker,
        };

        var threads = try allocator.alloc(*std.Thread, 10);
        for (threads) |*t| {
            t.* = try std.Thread.spawn(&context, downloadWork);
        }

        worker.start(file) catch {
            std.debug.warn("Download got interrupted\n", .{});
            return;
        };

        std.debug.warn("Finished downloading torrent\n", .{});
    }

    /// Returns the bounds of a piece by its index
    fn bounds(
        self: Self,
        index: usize,
        begin: *usize,
        end: *usize,
    ) void {
        const meta = self.file;
        begin.* = index * meta.piece_length;
        end.* = blk: {
            var length = begin.* + meta.piece_length;
            if (length > meta.size) {
                length = meta.size;
            }
            break :blk length;
        };
    }

    /// Calculates and returns the piece size
    fn pieceSize(self: Self, index: usize) usize {
        var begin: usize = undefined;
        var end: usize = undefined;
        self.bounds(index, &begin, &end);
        return end - begin;
    }
};

/// Downloads all pieces of work distributed to multiple peers/threads
fn downloadWork(ctx: *WorkerContext) !void {
    var worker = ctx.worker;
    if (worker.getClient()) |*client| {
        std.debug.warn("Attempt to connect to peer {}\n", .{client.peer.ip});
        client.connect() catch |err| {
            std.debug.warn("Could not connect to peer {} - err: {}\n", .{ client.peer.ip, err });
            return;
        };
        defer client.close();
        std.debug.warn("Connected to peer {}\n", .{client.peer.ip});

        try client.send(MessageType.Unchoke);
        try client.send(MessageType.Interested);

        // our work loop, try to download all pieces of work
        while (worker.next()) |*work| {
            // work is copied by value, so deinit the current object when leaving this function
            defer work.deinit();
            // if the peer does not have the piece, skip and put the piece back in the queue
            if (client.bitfield) |bitfield| {
                if (!bitfield.hasPiece(work.index)) {
                    try worker.put(work.*);
                    continue;
                }
            }

            // download the piece of work
            work.download(client) catch {
                try worker.put(work.*);
                return;
            };

            // sumcheck of its content, we don't want corrupt/incorrect data
            if (!work.eqlHash()) {
                try worker.put(work.*);
                continue;
            }

            // notify the peer we have the piece
            try client.sendHave(work.index);
            try worker.done(work.*);
        }
    }
}
