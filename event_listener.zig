const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 3) {
        std.log.err("Invalid number of args.", .{});
        return;
    }

    const cgroup_file = args[1];
    const cgroup_dir = std.fs.path.dirname(cgroup_file) orelse {
        std.log.err("Invalid path {s}", .{cgroup_file});
        return;
    };

    var event_ctrl_path = try std.fs.path.join(
        allocator,
        &.{ cgroup_dir, "cgroup.event_control" },
    );
    defer allocator.free(event_ctrl_path);

    var event_ctrl_fd = try std.fs.openFileAbsolute(event_ctrl_path, .{ .mode = .write_only });
    defer event_ctrl_fd.close();

    var oom_ctrl_fd = try std.fs.openFileAbsolute(cgroup_file, .{ .mode = .read_only });
    defer oom_ctrl_fd.close();

    const efd = try std.os.eventfd(0, 0);
    defer std.os.close(efd);

    var buf = [_]u8{0} ** 128;
    var line = try std.fmt.bufPrint(&buf, "{d} {d} {s}\x00", .{ efd, oom_ctrl_fd.handle, args[2] });
    _ = try event_ctrl_fd.write(line);

    var result_buf: [@sizeOf(u64)]u8 = undefined;
    while (true) {
        var ret = try std.os.read(efd, &result_buf);
        std.debug.assert(ret == @sizeOf(@TypeOf(result_buf)));

        std.fs.accessAbsolute(event_ctrl_path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.info("cgroup deleted", .{});
                break;
            },
            else => {
                std.log.err("cgroup no longer accessible", .{});
                break;
            },
        };

        std.log.info("{s} {s} Event Triggered", .{ args[1], args[2] });
    }
    std.log.debug("Exiting", .{});
}
