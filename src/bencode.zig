const std = @import("std");
const testing = std.testing;

/// Bencode allows for parsing Bencode data
/// It is up to the implementation to use nullable fields or not.
/// Currently this does not check if a field is mandatory or not.
/// Also, lists are currently not supported.
pub const Bencode = struct {
    const Self = @This();

    allocator: *std.mem.Allocator,
    cursor: usize = 0,
    buffer: []const u8,

    pub fn init(allocator: *std.mem.Allocator) Self {
        return Self{ .allocator = allocator, .buffer = undefined };
    }

    /// unmarshal tries to parse the given bencode bytes into Type T.
    pub fn unmarshal(
        self: *Self,
        comptime T: type,
        bytes: []const u8,
    ) !T {
        self.cursor = 0; // reset cursor
        self.buffer = bytes;
        var decoded: T = undefined;
        try self.parse(T, &decoded);
        return decoded;
    }

    /// Encodes the given struct into Bencode encoded bytes
    pub fn marshal(
        self: *Self,
        comptime T: type,
        value: var,
        buffer: []u8,
    ) !usize {
        self.cursor = 0;
        _ = try self.encode(T, value, buffer);
        return self.cursor;
    }

    fn parse(self: *Self, comptime T: type, value: *T) !void {
        var builder = Builder(T).init(value);

        // parse the bytes
        for (self.buffer) |c, i| {
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

                        switch (@typeInfo(T)) {
                            .Struct => |struct_info| {
                                inline for (struct_info.fields) |field| {
                                    // if field is current field, set it.
                                    if (std.mem.eql(u8, field.name, buffer)) {
                                        var child: field.field_type = undefined;
                                        try self.parse(field.field_type, &child);
                                        try builder.set(child, self.allocator);
                                    }
                                }
                            },
                            else => {
                                unreachable;
                            },
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
                'l' => {
                    self.cursor += 1;
                    const list = try self.parseList();
                    errdefer self.allocator.free(list);
                    try builder.set(list, self.allocator);
                    self.cursor += 1;
                },
                'e' => {
                    value.* = builder.val.*;
                    self.cursor += 1;
                    return;
                },
                else => {
                    return error.UnknownCharacter;
                },
            }
        }
        value.* = builder.val.*;
        return;
    }

    /// recursive function that constructs a byte array containing bencoded data
    fn encode(
        self: *Self,
        comptime T: type,
        value: var,
        buffer: []u8,
    ) !usize {
        std.mem.copy(u8, buffer[self.cursor..], "d");
        self.cursor += 1;
        switch (@typeInfo(T)) {
            .Struct => |info| {
                inline for (info.fields) |field| {
                    // save current field in a buffer so we can modify if required
                    // i.e. the field contains an underscode so we want to replace it with a space.
                    var field_name = try self.allocator.alloc(u8, field.name.len);
                    std.mem.copy(u8, field_name, field.name);
                    defer self.allocator.free(field_name);
                    if (std.mem.indexOf(u8, field_name, "_")) |index| {
                        field_name[index] = ' ';
                    }
                    switch (@typeInfo(field.field_type)) {
                        .Struct => |child| {
                            _ = try self.encode(field.field_type, @field(value, field.name), buffer);
                        },
                        .Int, .Float => {
                            const print_result = try std.fmt.bufPrint(buffer[self.cursor..], "{}:{}i{}e", .{
                                field.name.len,
                                field_name,
                                @field(value, field.name),
                            });
                            self.cursor += print_result.len;
                        },
                        else => {
                            var result = try std.fmt.bufPrint(buffer[self.cursor..], "{}:{}{}:{}", .{
                                field.name.len,
                                field_name,
                                @field(value, field.name).len,
                                @field(value, field.name),
                            });
                            self.cursor += result.len;
                        },
                    }
                }
            },
            else => return error.NotSupported,
        }
        std.mem.copy(u8, buffer[self.cursor..], "e");
        self.cursor += 1;

        return self.cursor;
    }

    // decodes a slice into a string based on the length provided in the slice
    // noted by xx: where xx is the length
    fn decodeString(self: *Self) ![]const u8 {
        const length: u64 = try self.decodeInt();
        const str = self.buffer[self.cursor .. self.cursor + length];
        self.cursor += length;
        return str;
    }

    // decodes the next integer found before the color (:) symbol
    fn decodeInt(self: *Self) !usize {
        const index = std.mem.indexOf(u8, self.buffer[self.cursor..], ":") orelse return error.UnexpectedCharacter;
        const int = self.buffer[self.cursor .. self.cursor + index];
        self.cursor += index + 1;

        return std.fmt.parseInt(usize, int, 10);
    }

    fn parseList(self: *Self) ![]const []const u8 {
        var list = std.ArrayList([]const u8).init(self.allocator);
        while (self.buffer[self.cursor] != 'e') {
            const str = try self.decodeString();
            try list.append(str);
        }
        return list.toOwnedSlice();
    }
};

/// Builder is a helper struct that set the fields on the given Type
/// based on the input given.
fn Builder(comptime T: type) type {
    return struct {
        const Self = @This();

        field: []const u8,
        state: State,
        val: *T,

        fn init(value: *T) Self {
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

        fn set(
            self: *Self,
            str: var,
            allocator: *std.mem.Allocator,
        ) !void {
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

                    // ensure T is a struct and get its fields
                    switch (@typeInfo(T)) {
                        .Struct => |struct_info| {
                            inline for (struct_info.fields) |field| {
                                // if field is current field, set it.
                                if (std.mem.eql(u8, field.name, buffer)) {
                                    if (@TypeOf(@field(self.val, field.name)) == @TypeOf(str)) {
                                        @field(self.val, field.name) = str;
                                    }
                                }
                            }
                        },
                        else => {
                            // Maybe implement later
                            return error.UnsupportedType;
                        },
                    }
                    self.state = .SetField;
                },
                else => {
                    // Only set a field when the input is of type []const u8
                    // as names cannot be of any other type. This will be inlined by the compiler.
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
    // allow newlines to increase readability of test
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

    const Announce = struct {
        announce: []const u8,
        comment: []const u8,
        creation_date: usize,
        info: Info,
    };

    const expected = Announce{
        .announce = "http://bttracker.debian.org:6969/announce",
        .comment = "\"Debian CD from cdimage.debian.org\"",
        .creation_date = 1573903810,
        .info = Info{
            .length = 351272960,
            .name = "debian-10.2.0-amd64-netinst.iso",
            .piece_length = 262144,
        },
    };

    var bencode = Bencode.init(testing.allocator);
    const result = try bencode.unmarshal(Announce, bencode_string);
    testing.expectEqual(expected.creation_date, result.creation_date);
    testing.expectEqualSlices(u8, expected.announce, result.announce);
    testing.expectEqualSlices(u8, expected.info.name, result.info.name);
    testing.expectEqualSlices(u8, expected.comment, result.comment);
}

test "Encode struct to Bencode" {
    const Child = struct {
        field: []const u8 = "other value",
    };
    const TestStruct = struct {
        name: []const u8 = "random value",
        length: usize = 1236,
        child: Child = Child{},
    };

    const value = TestStruct{};
    var bencode = Bencode.init(testing.allocator);
    var buffer = try testing.allocator.alloc(u8, 2048);
    const result = try bencode.marshal(TestStruct, value, buffer);
    defer testing.allocator.free(buffer);

    const expected = "d4:name12:random value6:lengthi1236ed5:field11:other valueee";
    testing.expectEqualSlices(u8, expected, buffer[0..result]);
}
