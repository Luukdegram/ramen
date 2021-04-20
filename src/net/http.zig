const std = @import("std");
const Url = @import("url.zig").Url;
const net = std.net;
const Allocator = std.mem.Allocator;

/// Sends a GET request to the given url.
/// Returns a `Response` that contains the statuscode, headers and body.
pub fn get(gpa: *Allocator, url: []const u8) !Response {
    const endpoint = try Url.init(url);

    // build our request header
    var buf: [4096]u8 = undefined;
    const get_string = try std.fmt.bufPrint(&buf, "GET {s} HTTP/1.1\r\nHOST: {s}\r\nConnection: close\r\n\r\n", .{
        endpoint.path,
        endpoint.host,
    });

    const socket = try net.tcpConnectToHost(gpa, endpoint.host, endpoint.port);
    defer socket.close();
    _ = try socket.write(get_string);

    var parser = HttpParser.init(gpa);
    return parser.parse(socket.reader());
}

pub const ParseError = error{NoStatusCode};

/// Http header with a `name` and `value`
pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Http Response that contains the statuscode, headers and body of a Http request.
/// deinit must be called to free its memory
pub const Response = struct {
    status_code: []const u8,
    headers: []Header,
    body: []const u8,
    gpa: *Allocator,

    fn deinit(self: @This()) void {
        self.gpa.free(self.status_code);
        self.gpa.free(self.headers);
        self.gpa.free(self.body);
    }
};

/// HttpParser can parse Http responses into a `Response` object.
/// It takes in an `io.InStream` and parses each line seperately.
/// Note that deinit has to be called on the response provided by `parse` to free the memory.
/// Currently the implementation is fairly basic and it parses most values as 'strings' such as the status code.
pub const HttpParser = struct {
    const Self = @This();
    state: State,
    gpa: *Allocator,

    /// State of the `HttpParser`
    const State = enum {
        status_code,
        header,
        body,
    };

    fn init(gpa: *Allocator) Self {
        return Self{ .gpa = gpa, .state = .status_code };
    }

    /// parse accepts an `io.Reader`, it will read all data it contains
    /// and tries to parse it into a `Response`. Can return `ParseError` if data is corrupt
    fn parse(self: *Self, reader: anytype) !Response {
        var response: Response = undefined;
        response.gpa = self.gpa;

        // per line we accept 4Kb, this should be enough
        var buffer: [4096]u8 = undefined;

        var headers = std.ArrayList(Header).init(self.gpa);
        errdefer headers.deinit(); // only deinit on errors as it is done automatically by toOwnedSlice()

        var body = std.ArrayList([]const u8).init(self.gpa);
        errdefer body.deinit();

        // read stream until end of file, parse each line
        while (try reader.readUntilDelimiterOrEof(&buffer, '\n')) |bytes| {
            switch (self.state) {
                .status_code => {
                    response.status_code = parseStatusCode(self.gpa, bytes) catch |err| return err;
                    self.state = .header;
                },
                .header => {
                    // read until all headers are parsed, if null is returned, assume data has started
                    // and set the current state to .Data
                    if (try parseHeader(self.gpa, bytes)) |header| {
                        try headers.append(header);
                    } else {
                        self.state = .body;
                    }
                },
                .body => {
                    const data = try parseData(self.gpa, bytes);
                    try body.append(data);
                },
            }
        }

        response.headers = headers.toOwnedSlice();
        response.body = try std.mem.join(self.gpa, "\n", body.toOwnedSlice());

        return response;
    }

    /// Attempts to retrieve the statuscode from given bytes, returns an error if no statuscode is found
    fn parseStatusCode(gpa: *Allocator, bytes: []u8) ![]const u8 {
        var parts = std.mem.split(bytes, " ");
        // skip first part
        if (parts.next() == null) return ParseError.NoStatusCode;
        // copy code part into buffer
        if (parts.next()) |code| {
            const buf = try gpa.alloc(u8, code.len);
            std.mem.copy(u8, buf, code);
            return buf;
        } else {
            return error.NoStatusCode;
        }
    }

    /// Attempts to parse a line into a header, returns `null` if no header is found
    fn parseHeader(allocator: *Allocator, bytes: []u8) !?Header {
        if (bytes.len == 0 or bytes[0] == 13) return null;
        var header: Header = undefined;
        // each header is defined by "name: value"
        var parts = std.mem.split(bytes, ": ");

        if (parts.next()) |name| {
            var buf = try allocator.alloc(u8, name.len);
            std.mem.copy(u8, buf, name);
            header.name = buf;
        } else {
            // no name found, free memory and return null so we can parse data
            // allocator.free(header);
            return null;
        }
        if (parts.next()) |val| {
            var buf = try allocator.alloc(u8, val.len);
            std.mem.copy(u8, buf, val);
            header.value = buf;
        }
        return header;
    }

    /// Simply copies the data in an allocated buffer so we can keep a reference to it
    fn parseData(allocator: *Allocator, bytes: []u8) ![]const u8 {
        var buf = try allocator.alloc(u8, bytes.len);
        std.mem.copy(u8, buf, bytes);
        return buf;
    }
};
