const std = @import("std");

/// Struct that contains the protocol, host and path of an Url.
pub const Url = struct {
    protocol: []const u8,
    host: []const u8,
    path: []const u8,
    port: u16,

    /// Parses the given string to build an `Url` object
    pub fn init(url: []const u8) !Url {
        var tmp = url;

        if (std.mem.eql(u8, url[0..7], "http://")) {
            tmp = url[7..];
        } else if (std.mem.eql(u8, url[0..8], "https://")) {
            tmp = url[8..];
        }

        var host: []const u8 = tmp;
        var path: []const u8 = "/";
        var port: u16 = 80;

        for (tmp) |c, i| {
            if (c == ':') {
                const index = std.mem.indexOf(u8, tmp[i..], "/") orelse unreachable;
                port = try std.fmt.parseInt(u16, tmp[i + 1 .. i + index], 10);
                host = tmp[0..i];
                path = tmp[i + index ..];
                break;
            }
            if (c == '/') {
                host = tmp[0..i];
                path = tmp[i..];
                break;
            }
        }

        // for now we only support HTTP
        return Url{
            .protocol = "http",
            .host = host,
            .path = path,
            .port = port,
        };
    }
};
