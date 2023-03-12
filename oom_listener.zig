const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len != 2) {
        std.log.err("Invalid number of args.", .{});
        return;
    }

    var path_chunks = [_][]const u8{undefined} ** 2;

    path_chunks[0] = args[1];
    path_chunks[1] = "cgroup.event_control";

    var event_ctrl_path = try std.mem.join(allocator, "/", &path_chunks);
    defer allocator.free(event_ctrl_path);

    path_chunks[1] = "memory.oom_control";
    var oom_ctrl_path = try std.mem.join(allocator, "/", &path_chunks);
    defer allocator.free(oom_ctrl_path);

    var event_ctrl_fd = try std.fs.openFile(event_ctrl_path, .{ .mode = .write_only });
    defer event_ctrl_fd.close();

    var oom_ctrl_fd = try std.fs.openFile(oom_ctrl_path, .{ .mode = .read_only });
    defer oom_ctrl_fd.close();

    const efd = try std.os.eventfd(0, 0);
    defer std.os.close(efd);

    var buf = [_]u8{0} ** 128;
    var line = try std.fmt.bufPrint(&buf, "{d} {d}\x00", .{ efd, oom_ctrl_fd.handle });
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
                std.log.err("cgroup no  accessible", .{});
                std.os.exit(1);
            },
        };

        std.log.info("OOM Event Triggered", .{});
    }
}
