const std = @import("std");

fn readLine(reader: anytype, buffer: []u8) !?[]const u8 {
    return (try reader.readUntilDelimiterOrEof(buffer, '\n')) orelse null;
}

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    const stdin = std.io.getStdIn().reader();

    const allocator = std.heap.page_allocator;
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var gigs: i64 = 4;

    if (args.len > 1) {
        gigs = std.fmt.parseUnsigned(u32, args[1], 10) catch brk: {
            try stderr.print("Couldn't parse {s}, ignoring\n", .{args[1]});
            break :brk gigs;
        };
    }

    var data = std.ArrayList([]u8).init(allocator);
    defer data.deinit();

    for (0..@intCast(usize, gigs)) |_| {
        var d = try allocator.alloc(u8, 1024 * 1024 * 1024);
        for (d) |*byte| byte.* = 0;
        try data.append(d);
        try stdout.print("+", .{});
    }

    var buffer: [128]u8 = undefined;

    while (true) {
        try stdout.print("\nCurrent RAM [{}G]: ", .{data.items.len});
        var line = (try stdin.readUntilDelimiterOrEof(&buffer, '\n')) orelse continue;
        if (std.mem.eql(u8, "q", line)) break;

        var diff = std.fmt.parseInt(i32, line, 10) catch {
            try stderr.print("Error: Invalid value, enter positive or negative number or q to quit.\n", .{});
            continue;
        };

        if (diff < 0) {
            for (0..std.math.absCast(diff)) |_| {
                var d = data.popOrNull() orelse break;
                allocator.free(d);
                try stdout.print("-", .{});
            }
        } else if (diff > 0) {
            for (0..@intCast(usize, diff)) |_| {
                var d = try allocator.alloc(u8, 1024 * 1024 * 1024);
                for (d) |*byte| byte.* = 0;
                try data.append(d);
                try stdout.print("+", .{});
            }
        }
    }

    defer {
        for (data.items) |*d| allocator.free(d.*);
    }
}
