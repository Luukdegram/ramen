const std = @import("std");
const testing = std.testing;

const ParserError = error{BadStringLength};

const Bencode = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    cursor: usize = 0,
    buffer: []const u8,

    pub fn init(allocator: *std.mem.Allocator) Self {
        return Self{ .allocator = allocator, .buffer = undefined };
    }

    /// unmarshal tries to parse the given bencode bytes into Type T.
    pub fn unmarshal(self: *Self, bytes: []const u8, comptime T: type) !T {
        self.cursor = 0; // reset cursor
        self.buffer = bytes;
        var value: T = undefined;
        var builder = Builder(T).init(value);

        // parse the bytes
        for (bytes) |c, i| {
            if (i < self.cursor) {
                // current byte is behind cursor, which means we already parsed it
                // skip to the next byte
                continue;
            }
            switch (c) {
                // also detect next lines.
                '\n' => self.cursor += 1,
                // defines string length
                '0'...'9' => {
                    const str = try self.decodeString();
                    try builder.set(str, self.allocator);
                },
                // directory -> new struct
                'd' => {
                    if (builder.map()) {

                        // save current field in a buffer so we can modify if required
                        // i.e. the field contains spaces so we want to replace it with an underscore.
                        var buffer = try self.allocator.alloc(u8, builder.field.len);
                        std.mem.copy(u8, buffer, builder.field);
                        defer self.allocator.free(buffer);
                        if (std.mem.indexOf(u8, buffer, " ")) |index| {
                            buffer[index] = '_';
                        }

                        // loop through fields so we can get the correct fieldname
                        inline for (std.meta.fields(T)) |field| {
                            std.debug.warn("\nField: {}", .{field.name});
                            // if field is current field, set it.
                            if (std.mem.eql(u8, field.name, buffer)) {
                                var ben = Bencode.init(self.allocator);
                                var result = ben.unmarshal(
                                    self.buffer[self.cursor..],
                                    @TypeOf(@field(builder.val, field.name)),
                                );
                            }
                        }
                    }

                    self.cursor += 1;
                },
                // integer size, read until e
                'i' => {
                    builder.buildValue();
                    const length = std.mem.indexOf(u8, self.buffer[self.cursor..], "e") orelse return error.InvalidBencode;
                    const buf = self.buffer[self.cursor + 1 .. self.cursor + length];
                    const val: usize = try std.fmt.parseInt(usize, buf, 10);
                    try builder.set(val, self.allocator);
                    self.cursor += length + 1;
                },
                // array
                'l' => {},
                'e' => return builder.val,
                else => {
                    return error.UnknownCharacter;
                },
            }
        }

        return builder.val;
    }

    fn decodeString(self: *Self) ![]const u8 {
        const length: u64 = try self.decodeInt();
        const str = self.buffer[self.cursor .. self.cursor + length];
        self.cursor += length;
        return str;
    }

    fn decodeInt(self: *Self) !usize {
        const index = std.mem.indexOf(u8, self.buffer[self.cursor..], ":") orelse 0;
        const int = self.buffer[self.cursor .. self.cursor + index];
        self.cursor += index + 1;

        return try std.fmt.parseInt(usize, int, 10);
    }
};

fn Builder(comptime T: type) type {
    return struct {
        const Self = @This();

        field: []const u8,
        state: State,
        val: T,

        fn init(value: T) Self {
            return Self{
                .state = undefined,
                .val = value,
                .field = undefined,
            };
        }

        const State = enum {
            SetValue,
            SetField,
            SetStruct,
        };

        fn map(self: *Self) bool {
            if (self.state != .SetValue) return false;
            self.state = .SetStruct;
            return true;
        }

        fn buildValue(self: *Self) void {
            self.state = .SetValue;
        }

        fn set(self: *Self, str: var, allocator: *std.mem.Allocator) !void {
            switch (self.state) {
                .SetValue, .SetStruct => {
                    // save current field in a buffer so we can modify if required
                    // i.e. the field contains spaces so we want to replace it with an underscore.
                    var buffer = try allocator.alloc(u8, self.field.len);
                    std.mem.copy(u8, buffer, self.field);
                    defer allocator.free(buffer);
                    if (std.mem.indexOf(u8, buffer, " ")) |index| {
                        buffer[index] = '_';
                    }

                    // loop through fields so we can get the correct fieldname
                    inline for (std.meta.fields(T)) |field| {
                        // if field is current field, set it.
                        if (std.mem.eql(u8, field.name, buffer)) {
                            if (@TypeOf(@field(self.val, field.name)) == @TypeOf(str)) {
                                @field(self.val, field.name) = str;
                            }
                            self.state = .SetField;
                        }
                    }
                },
                else => {
                    if (@TypeOf(str) == []const u8) {
                        self.field = str;
                    }
                    self.state = .SetValue;
                },
            }
        }
    };
}

test "unmarshal basic string" {
    var bencode_string =
        \\d
        \\8:announce
        \\41:http://bttracker.debian.org:6969/announce
        \\7:comment
        \\35:"Debian CD from cdimage.debian.org"
        \\13:creation date
        \\i1573903810e
        \\4:info
        \\d
        \\6:length
        \\i351272960e
        \\4:name
        \\31:debian-10.2.0-amd64-netinst.iso
        \\12:piece length
        \\i262144e
        \\e
        \\e
    ;
    const Info = struct {
        length: usize,
        name: []const u8,
        piece_length: usize,
    };

    const Bencode_struct = struct {
        announce: []const u8,
        comment: []const u8,
        creation_date: usize,
        info: Info,
    };

    var bencode = Bencode.init(testing.allocator);
    const result = try bencode.unmarshal(bencode_string, Bencode_struct);
    std.debug.warn("\nannounce: {}\n", .{result.announce});
}
