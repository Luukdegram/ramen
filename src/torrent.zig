const std = @import("std");

const Peer = @import("peer.zig").Peer;
const TorrentFile = @import("torrent_file.zig").TorrentFile;
const Worker = @import("worker.zig").Worker;
const Work = @import("worker.zig").Work;
const WorkerContext = @import("worker.zig").WorkerContext;

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
        stream: var,
    ) !void {
        std.debug.warn("Downloaded started for torrent: {}\n", .{self.file.name});

        // Creates jobs for all pieces that needs to be downloaded
        var jobs = try allocator.alloc(Work, self.file.piece_hashes.len);
        for (self.file.piece_hashes) |hash, i| {
            const work = Work{
                .index = i,
                .hash = hash,
                .size = self.pieceSize(i),
            };
            jobs[i] = work;
        }

        var mutex = std.Mutex.init();
        defer mutex.deinit();

        var worker = Worker.init(allocator, &mutex, &self, jobs);

        var context = WorkerContext{
            .worker = &worker,
        };

        var threads = try allocator.alloc(*std.Thread, 2);
        for (threads) |*t| {
            t.* = try std.Thread.spawn(&context, downloadWork);
        }

        for (threads) |t| {
            t.wait();
        }
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
            var length = @ptrToInt(begin) + meta.piece_length;
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
    std.debug.warn("Started work", .{});
    var worker = ctx.worker;
    if (worker.getClient()) |*client| {
        client.connect() catch |err| {
            std.debug.warn("Could not connect to peer {} - err: {}\n", .{ client.peer.ip, err });
            return;
        };
        std.debug.warn("Connected to peer {}", .{client.peer.ip});
        defer client.close();
    }
}
