const std = @import("std");
const Url = @import("url.zig").Url;
const net = std.net;

// TODO remove this when finished testing
pub fn main() !void {
    const allocator = &std.heap.ArenaAllocator.init(std.heap.page_allocator).allocator;
    const url = "httpbin.org/get?test=1";
    const resp = try get(allocator, url);
    defer resp.deinit();

    std.debug.warn("{}", .{resp.body});
}

/// Sends a GET request to the given url.
/// Returns a `Response` that contains the statuscode, headers and body.
pub fn get(allocator: *std.mem.Allocator, url: []const u8) !Response {
    const endpoint = Url.init(url);

    // build our request header
    var buf = try allocator.alloc(u8, 4096);
    defer allocator.free(buf);
    const get_string = try std.fmt.bufPrint(buf, "GET {} HTTP/1.1\r\nHOST: {}\r\nConnection: close\r\n\r\n", .{
        endpoint.path,
        endpoint.host,
    });

    const socket = try net.tcpConnectToHost(allocator, endpoint.host, 80);
    defer socket.close();
    _ = try socket.write(get_string);

    var parser = HttpParser.init(allocator);
    return try parser.parse(socket.inStream());
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
    statusCode: []const u8,
    headers: []Header,
    body: []const u8,
    allocator: *std.mem.Allocator,

    fn deinit(self: @This()) void {
        self.allocator.free(self.statusCode);
        self.allocator.free(self.headers);
        self.allocator.free(self.body);
    }
};

/// HttpParser can parse Http responses into a `Response` object.
/// It takes in an `io.InStream` and parses each line seperately.
/// Note that deinit has to be called on the response provided by `parse` to free the memory.
/// Currently the implementation is fairly basic and it parses most values as 'strings' such as the status code.
pub const HttpParser = struct {
    const Self = @This();
    state: State = .StatusCode,
    allocator: *std.mem.Allocator,

    /// State of the `HttpParser`
    const State = enum {
        StatusCode,
        Header,
        Body,
    };

    fn init(allocator: *std.mem.Allocator) Self {
        return Self{ .allocator = allocator };
    }

    /// parse accepts an `io.InStream`, it will read all data it contains
    /// and tries to parse it into a `Response`. Can return `ParseError` if data is corrupt
    fn parse(
        self: *Self,
        stream: std.io.InStream(
            std.fs.File,
            std.os.ReadError,
            std.fs.File.read,
        ),
    ) !Response {
        var response: Response = undefined;
        response.allocator = self.allocator;

        // per line we accept 4Kb, this should be enough
        var buffer = try self.allocator.alloc(u8, 4096);
        defer self.allocator.free(buffer);

        var headers = std.ArrayList(Header).init(self.allocator);
        errdefer headers.deinit(); // only deinit on errors as it is done automatically by toOwnedSlice()

        var body = std.ArrayList([]const u8).init(self.allocator);
        errdefer body.deinit();

        // read stream until end of file, parse each line
        while (try stream.readUntilDelimiterOrEof(buffer, '\n')) |bytes| {
            switch (self.state) {
                .StatusCode => {
                    response.statusCode = parseStatusCode(self.allocator, bytes) catch |err| return err;
                    self.state = .Header;
                },
                .Header => {
                    // read until all headers are parsed, if null is returned, assume data has started
                    // and set the current state to .Data
                    if (try parseHeader(self.allocator, bytes)) |header| {
                        try headers.append(header);
                    } else {
                        self.state = .Body;
                    }
                },
                .Body => {
                    const data = try parseData(self.allocator, bytes);
                    try body.append(data);
                },
            }
        }

        response.headers = headers.toOwnedSlice();
        response.body = try std.mem.join(self.allocator, "\n", body.toOwnedSlice());

        return response;
    }

    /// Attempts to retrieve the statuscode from given bytes, returns an error if no statuscode is found
    fn parseStatusCode(allocator: *std.mem.Allocator, bytes: []u8) ![]const u8 {
        var parts = std.mem.split(bytes, " ");
        // skip first part
        if (parts.next() == null) return ParseError.NoStatusCode;
        // copy code part into buffer
        if (parts.next()) |code| {
            var buf = try allocator.alloc(u8, code.len);
            std.mem.copy(u8, buf, code);
            return buf;
        } else {
            return error.NoStatusCode;
        }
    }

    /// Attempts to parse a line into a header, returns `null` if no header is found
    fn parseHeader(allocator: *std.mem.Allocator, bytes: []u8) !?Header {
        if (bytes.len == 0 or bytes[0] == 13) return null;
        var header = try allocator.alloc(Header, 1);
        // each header is defined by "name: value"
        var parts = std.mem.split(bytes, ": ");

        if (parts.next()) |name| {
            var buf = try allocator.alloc(u8, name.len);
            std.mem.copy(u8, buf, name);
            header[0].name = buf;
        } else {
            // no name found, free memory and return null so we can parse data
            allocator.free(header);
            return null;
        }
        if (parts.next()) |val| {
            var buf = try allocator.alloc(u8, val.len);
            std.mem.copy(u8, buf, val);
            header[0].value = buf;
        }
        return header[0];
    }

    /// Simply copies the data in an allocated buffer so we can keep a reference to it
    fn parseData(allocator: *std.mem.Allocator, bytes: []u8) ![]const u8 {
        var buf = try allocator.alloc(u8, bytes.len);
        std.mem.copy(u8, buf, bytes);
        return buf;
    }
};
