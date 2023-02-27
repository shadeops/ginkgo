const std = @import("std");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var gigs: usize = 4;
        
    if (args.len > 1) {
        gigs = std.fmt.parseUnsigned(usize, args[1], 10) catch brk: {
            std.debug.print("Couldn't parse {s}, ignoring\n", .{args[1]});
            break :brk gigs;
        };
    }

    var data = try allocator.alloc([]u8, gigs);
    defer allocator.free(data);
    for (data, 0..) |*d, i| {
        d.* = try allocator.alloc(u8, 1024*1024*1024);
        for (d.*) |*byte| byte.* = 0;
        std.debug.print("Allocated {}G\n", .{i+1}); 
    }

    //std.time.sleep(10000000000);
    while (true) {}

    defer {
        for (data) |*d| allocator.free(d.*);
    }
}
