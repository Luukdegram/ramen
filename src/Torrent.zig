const std = @import("std");

const Peer = @import("Peer.zig");
const TorrentFile = @import("torrent_file.zig").TorrentFile;
const Worker = @import("worker.zig").Worker;
const Work = @import("worker.zig").Work;
const Client = @import("net/Tcp_client.zig");

const Torrent = @This();

/// peers is a list of seeders we can connect to
peers: []const Peer,
/// unique id to identify ourselves to others
peer_id: [20]u8,
/// the corresponding torrent file that contains its meta data.
file: *TorrentFile,

/// Downloads the torrent and writes to the given stream
pub fn download(self: Torrent, gpa: *std.mem.Allocator, path: []const u8) !void {
    std.debug.print("Download started for torrent: {s}\n", .{self.file.name});

    var work_pieces = try std.ArrayList(Work).initCapacity(gpa, self.file.piece_hashes.len);
    defer work_pieces.deinit();

    // Creates jobs for all pieces that needs to be downloaded
    for (self.file.piece_hashes) |hash, i| {
        var index = @intCast(u32, i);
        work_pieces.appendAssumeCapacity(Work.init(index, hash, self.pieceSize(index), gpa));
    }

    var mutex = std.Thread.Mutex{};

    // Create our file with an exclusive lock, so only this process can write to it and
    // others cannot temper with it while we're in the process of downloading
    const file = try std.fs.cwd().createFile(path, .{ .lock = .Exclusive });
    defer file.close();

    var worker = Worker.init(gpa, &mutex, &self, &work_pieces, file);

    std.debug.print("Peer size: {d}\n", .{self.peers.len});
    std.debug.print("Pieces to download: {d}\n", .{work_pieces.items.len});
    const threads = try gpa.alloc(*std.Thread, try std.Thread.cpuCount());
    defer gpa.free(threads);
    for (threads) |*t| {
        t.* = try std.Thread.spawn(downloadWork, &worker);
    }

    std.debug.print("Downloaded\t\tSize\t\t% completed\n", .{});
    for (threads) |t| {
        t.wait();
    }

    std.debug.print("\nFinished downloading torrent", .{});
}

/// Sets the `begin` and `end` of a piece for a given `index`
fn bounds(self: Torrent, index: u32, begin: *u32, end: *u32) void {
    const meta = self.file;
    begin.* = index * @intCast(u32, meta.piece_length);
    end.* = blk: {
        var length: usize = begin.* + meta.piece_length;
        if (length > meta.size) {
            length = meta.size;
        }
        break :blk @intCast(u32, length);
    };
}

/// Calculates and returns the piece size for the given `index`
fn pieceSize(self: Torrent, index: u32) u32 {
    var begin: u32 = undefined;
    var end: u32 = undefined;
    self.bounds(index, &begin, &end);
    return end - begin;
}

/// Downloads all pieces of work distributed to multiple peers/threads
fn downloadWork(worker: *Worker) !void {
    if (worker.getClient()) |*client| {
        client.connect() catch return;
        defer client.close(worker.gpa);

        // try client.send(.unchoke);
        try client.send(.interested);

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
            work.download(client) catch |err| {
                try worker.put(work.*);
                switch (err) {
                    error.ConnectionResetByPeer, error.EndOfStream => return, // peer slams the door and disconnects
                    error.OutOfMemory => return, // we ran out of memory, close this connection to free up some of it
                    // in other cases, skip this work piece and try again
                    else => continue,
                }
            };

            // sumcheck of its content, we don't want corrupt/incorrect data
            if (!work.eqlHash()) {
                try worker.put(work.*);
                continue;
            }

            // notify the peer we have the piece
            try client.sendHave(work.index);
            try worker.write(work);
        }
    }
}
