const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = std.meta;
const trait = meta.trait;
const testing = std.testing;

/// Creates a new Deserializer type for the given reader type
pub fn Deserializer(comptime ReaderType: type) type {
    return struct {
        const Self = @This();
        /// Reader that is being read from while deserializing
        reader: ReaderType,
        gpa: *Allocator,
        /// Last character that was read from the stream
        last_char: u8,

        pub const Error = ReaderType.Error || std.fmt.ParseIntError ||
            error{ OutOfMemory, UnsupportedType, EndOfStream };

        const Pair = struct { key: []const u8, value: Value };

        /// Represents a bencode value
        const Value = union(enum) {
            bytes: []u8,
            int: usize,
            list: []Value,
            dictionary: []Pair,

            fn deinit(self: Value, gpa: *Allocator) void {
                switch (self) {
                    .bytes => |bytes| gpa.free(bytes),
                    .int => {},
                    .list => |list| {
                        for (list) |item| item.deinit(gpa);
                        gpa.free(list);
                    },
                    .dictionary => |dict| {
                        for (dict) |pair| {
                            gpa.free(pair.key);
                            pair.value.deinit(gpa);
                        }
                        gpa.free(dict);
                    },
                }
            }

            /// Attempts to convert a `Value` into given zig type `T`
            fn toZigType(self: Value, comptime T: type, gpa: *Allocator) Error!T {
                if (T == []u8 or T == []const u8) return self.bytes;
                switch (@typeInfo(T)) {
                    .Struct => {
                        var struct_value: T = undefined;
                        inline for (meta.fields(T)) |field| {
                            if (self.getField(field.name)) |pair| {
                                const field_value = try pair.value.toZigType(field.field_type, gpa);
                                @field(struct_value, field.name) = @as(field.field_type, field_value);
                            }
                        }
                        return struct_value;
                    },
                    .Int => return @as(T, self.int),
                    .Optional => |opt| return try self.toZigType(opt.child, gpa),
                    .Pointer => |ptr| switch (ptr.size) {
                        .Slice => {
                            const ChildType = meta.Child(T);
                            var list = std.ArrayList(ChildType).init(gpa);
                            defer list.deinit();

                            for (self.list) |item| {
                                const element = try item.toZigType(ChildType, gpa);
                                try list.append(element);
                            }
                            return @as(T, list.toOwnedSlice());
                        },
                        .One => try self.toZigType(ptr.child, gpa),
                        else => return error.Unsupported,
                    },
                    else => return error.UnsupportedType,
                }
            }

            /// Asserts `Value` is Dictionary and returns dictionary pair if it contains given key
            /// else returns null
            fn getField(self: Value, key: []const u8) ?Pair {
                return for (self.dictionary) |pair| {
                    if (eql(key, pair.key)) break pair;
                } else null;
            }

            /// Checks if a field name equals that of a key
            /// replaces '_' with a ' ' if needed as bencode allows keys to have spaces
            fn eql(field: []const u8, key: []const u8) bool {
                if (field.len != key.len) return false;
                return for (field) |c, i| {
                    if (c != key[i]) {
                        if (c == '_' and key[i] == ' ') continue;
                        break false;
                    }
                } else true;
            }
        };

        pub fn init(gpa: *Allocator, reader: ReaderType) Self {
            return .{ .reader = reader, .gpa = gpa, .last_char = undefined };
        }

        /// Deserializes the current reader's stream into the given type `T`
        /// Rather than supplier a buffer, it will allocate the data it has read
        /// and can be freed upon calling `deinit` afterwards.
        pub fn deserialize(self: *Self, comptime T: type) Error!T {
            if (@typeInfo(T) != .Struct) @compileError("T must be a struct Type.");

            try self.nextByte(); // go to first byte
            const result = try self.deserializeValue();
            std.debug.assert(self.last_char == 'e');
            return try result.toZigType(T, self.gpa);
        }

        /// Reads the next byte from the reader and returns it
        fn nextByte(self: *Self) Error!void {
            const byte = try self.reader.readByte();
            self.last_char = byte;
            while (byte == '\n') {
                try self.nextByte();
            }
            return;
        }

        fn deserializeValue(self: *Self) Error!Value {
            return switch (self.last_char) {
                '0'...'9' => |c| Value{ .bytes = try self.deserializeBytes() },
                'i' => blk: {
                    try self.nextByte(); // skip 'i'
                    break :blk Value{ .int = try self.deserializeLength() };
                },
                'l' => Value{ .list = try self.deserializeList() },
                'd' => Value{ .dictionary = try self.deserializeDict() },
                ' ', '\n' => return try self.deserializeValue(),
                else => unreachable,
            };
        }

        /// Deserializes a slice of bytes
        fn deserializeBytes(self: *Self) Error![]u8 {
            const len = try self.deserializeLength();
            const value = try self.gpa.alloc(u8, len);
            try self.reader.readNoEof(value);
            self.last_char = value[len - 1];
            return value;
        }

        /// Reads until it finds ':' and returns the integer value in front of it
        fn deserializeLength(self: *Self) Error!usize {
            var list = std.ArrayList(u8).init(self.gpa);
            defer list.deinit();

            while (self.last_char >= '0' and self.last_char <= '9') : (try self.nextByte()) {
                try list.append(self.last_char);
            }

            // All integers in Bencode are radix 10
            const integer = try std.fmt.parseInt(usize, list.items, 10);
            return integer;
        }

        /// Deserializes into a slice of `Value` until it finds the 'e'
        fn deserializeList(self: *Self) Error![]Value {
            var list = std.ArrayList(Value).init(self.gpa);
            defer list.deinit();
            errdefer for (list.items) |item| item.deinit(self.gpa);

            while (self.last_char != 'e') : (try self.nextByte()) {
                const value = try self.deserializeValue();
                try list.append(value);
            }
            return list.toOwnedSlice();
        }

        /// Deserializes a dictionary bencode object into a slice of `Pair`
        fn deserializeDict(self: *Self) Error![]Pair {
            var list = std.ArrayList(Pair).init(self.gpa);
            defer list.deinit();
            errdefer for (list.items) |pair| {
                self.gpa.free(pair.key);
                pair.value.deinit(self.gpa);
            };

            // go to first byte after 'd'
            try self.nextByte();

            while (self.last_char != 'e') : (try self.nextByte()) {
                const key = try self.deserializeBytes();
                try self.nextByte();
                const value = try self.deserializeValue();
                try list.append(.{ .key = key, .value = value });
            }
            return list.toOwnedSlice();
        }
    };
}

/// Returns a new deserializer for the given `reader`
pub fn deserializer(gpa: *Allocator, reader: anytype) Deserializer(@TypeOf(reader)) {
    return Deserializer(@TypeOf(reader)).init(gpa, reader);
}

/// Creates a Serializer type for the given writer type
pub fn Serializer(comptime WriterType: anytype) type {
    return struct {
        writer: WriterType,

        const Self = @This();

        pub const Error = WriterType.Error || error{OutOfMemory};

        /// Creates new instance of the Serializer type
        pub fn init(writer: WriterType) Self {
            return .{ .writer = writer };
        }

        /// Serializes the given value to bencode and writes the result to the writer
        pub fn serialize(self: Self, value: anytype) Error!void {
            const T = @TypeOf(value);
            if (T == []u8 or T == []const u8) {
                return try self.serializeString(value);
            }

            switch (@typeInfo(T)) {
                .Struct => try self.serializeStruct(value),
                .Int => try self.serializeInt(value),
                .Pointer => |ptr| switch (ptr.size) {
                    .Slice => try self.serializeList(value),
                    .One => try self.serialize(ptr.child),
                    .C, .Many => unreachable, // unsupported
                },
                .Optional => |opt| try self.serialize(opt.child),
                else => unreachable, // unsupported
            }
        }

        /// Serializes a struct into bencode
        fn serializeStruct(self: Self, value: anytype) Error!void {
            try self.writer.writeByte('d');
            inline for (meta.fields(@TypeOf(value))) |field| {
                try self.writer.print("{d}:{s}", .{ field.name.len, &encodeFieldName(field.name) });
                try self.serialize(@field(value, field.name));
            }
            try self.writer.writeByte('e');
        }

        /// Encodes a field name to bencode field by replacing underscores to spaces
        fn encodeFieldName(comptime name: []const u8) [name.len]u8 {
            var result: [name.len]u8 = undefined;
            for (name) |c, i| {
                const actual = if (c == '_') ' ' else c;
                result[i] = actual;
            }
            return result;
        }

        /// Serializes an integer to bencode integer
        fn serializeInt(self: Self, value: anytype) Error!void {
            try self.writer.print("i{d}e", .{value});
        }

        /// Serializes a slice of bytes to bencode string
        fn serializeString(self: Self, value: []const u8) Error!void {
            try self.writer.print("{d}:{s}", .{ value.len, value });
        }

        /// Serializes a slice of elements to bencode list
        fn serializeList(self: Self, value: anytype) Error!void {
            try self.writer.writeByte('l');
            for (value) |element| try self.serialize(element);
            try self.writer.writeByte('e');
        }
    };
}

/// Creates a new serializer instance with a Serializer type based on the given writer
pub fn serializer(writer: anytype) Serializer(@TypeOf(writer)) {
    return Serializer(@TypeOf(writer)).init(writer);
}

test "Deserialize Bencode to Zig struct" {
    // allow newlines to increase readability of test
    var bencode_string =
        "d8:announce41:http://bttracker.debian.org:6969/announce" ++
        "7:comment35:\"Debian CD from cdimage.debian.org\"13:creation date" ++
        "i1573903810e4:infod6:lengthi351272960e4:name31:debian-10.2.0-amd64-netinst.iso" ++
        "12:piece lengthi262144eee";

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

    var in = std.io.fixedBufferStream(bencode_string);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var des = deserializer(&arena.allocator, in.reader());
    const result = try des.deserialize(Announce);
    testing.expectEqual(expected.creation_date, result.creation_date);
    testing.expectEqualStrings(expected.announce, result.announce);
    testing.expectEqualStrings(expected.info.name, result.info.name);
    testing.expectEqualStrings(expected.comment, result.comment);
    testing.expectEqual(expected.info.length, result.info.length);
}

test "Serialize Zig value to Bencode" {
    const Child = struct {
        field: []const u8,
    };

    const TestStruct = struct {
        name: []const u8,
        length: usize,
        child: Child,
    };

    const value = TestStruct{
        .name = "random value",
        .length = 1236,
        .child = .{ .field = "other value" },
    };

    var list = std.ArrayList(u8).init(testing.allocator);
    defer list.deinit();

    var ser = serializer(list.writer());
    try ser.serialize(value);

    const expected = "d4:name12:random value6:lengthi1236e5:childd5:field11:other valueee";
    testing.expectEqualStrings(expected, list.items);
}
