const std = @import("std");
const testing = std.testing;

const ParserError = error{BadStringLength};

const Bencode = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    cursor: usize = 0,
    buffer: []u8,

    pub fn init(allocator: *std.mem.Allocator) Self {
        return Self{ .allocator = allocator, .buffer = undefined };
    }

    /// unmarshal tries to parse the given bencode bytes into Type T.
    pub fn unmarshal(self: Self, bytes: []u8, comptime T: var) !T {
        self.cursor = 0; // reset cursor
        self.buffer = bytes;
        builder = Builder.init(T);

        // parse the bytes
        for (bytes) |c, i| {
            if (i < self.cursor) {
                // current byte is behind cursor, which means we already parsed it
                // skip to the next byte
                continue;
            }
            switch (c) {
                '0'...'9' => {
                    const str = self.decodeString();
                    if (@hasField(T, str)) {}
                },
                'd' => {},
                'i' => {
                    const length = try std.mem.indexOf(u8, self.bytes[self.cursor..], 'e');
                    const buf = self.buffer[self.cursor .. self.cursor + length];
                    self.cursor += length;
                },
            }
        }
    }

    fn decodeString(self: Self) ![]const u8 {
        const length = self.decodeInt() catch |err| return ParserError.BadStringLength;
        const str = self.bytes[self.cursor .. self.cursor + length];
        self.cursor += length;
        return str;
    }

    fn decodeInt(self: Self) !usize {
        const index = std.mem.indexOf(u8, self.bytes[self.cursor..], ":") orelse 0;
        const int = self.bytes[self.cursor .. self.cursor + index];
        self.cursor += index;
        return try std.fmt.parseInt(usize, int, 10);
    }
};

const Builder = struct {
    const Self = @This();

    field: []const u8,
    state: State,
    val: var,

    fn init(val: var) Self {
        return Self{
            .state = .String,
            .val = val,
            .field = undefined,
        };
    }

    const State = enum {
        String,
        Map,
        Array,
    };

    fn string(self: Self, str: []const u8) void {
        self.field = str;
        self.state = .String;
    }

    fn int(self: Self, val: usize) void {
        @field(self.val, self.field) = val;
    }
};

test "unmarshal basic string" {
    var bencode = Bencode.init(testing.allocator);
}
