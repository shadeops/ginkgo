const std = @import("std");
const builtin = @import("builtin");

const MemInfo = @This();

total: usize,
free: usize,
available: usize,
cached: usize,
swap_total: usize,
swap_free: usize,

pub fn getMemInfo() !MemInfo {
    if (builtin.target.os.tag != .linux)
        @compileError("Unsupported operating system " ++ @tagName(builtin.target.os.tag));

    var line_buf: [1024]u8 = undefined;

    var meminfo_handle = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer meminfo_handle.close();

    var reader = meminfo_handle.reader();
    var meminfo: MemInfo = undefined;
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        var tokens = std.mem.tokenize(u8, line, " ");
        var entry = tokens.next() orelse continue;
        var value_str = tokens.next() orelse continue;
        var value = try std.fmt.parseUnsigned(usize, value_str, 10);
        // meminfo is in kB
        value *= 1024;
        if (std.mem.eql(u8, entry, "MemTotal:")) {
            meminfo.total = value;
        } else if (std.mem.eql(u8, entry, "MemFree:")) {
            meminfo.free = value;
        } else if (std.mem.eql(u8, entry, "MemAvailable:")) {
            meminfo.available = value;
        } else if (std.mem.eql(u8, entry, "Cached:")) {
            meminfo.cached = value;
        } else if (std.mem.eql(u8, entry, "SwapTotal:")) {
            meminfo.swap_total = value;
        } else if (std.mem.eql(u8, entry, "SwapFree:")) {
            meminfo.swap_free = value;
        }
    }
    return meminfo;
}

pub fn update(self: *MemInfo) !void {
    self.* = try getMemInfo();
}
