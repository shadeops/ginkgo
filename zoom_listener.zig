const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const event_ctrl_path = "./cgroup/ginkgo/cgroup.event_control";
    const oom_ctrl_path = "./cgroup/ginkgo/memory.oom_control";

    const cwd = std.fs.cwd();

    var event_ctrl_fd = try cwd.openFile(event_ctrl_path, .{ .mode = .write_only });
    defer event_ctrl_fd.close();

    var oom_ctrl_fd = try cwd.openFile(oom_ctrl_path, .{ .mode = .read_only });
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

        cwd.access(event_ctrl_path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => {
                _ = try stderr.write("cgroup deleted\n");
                break;
            },
            else => {
                _ = try stderr.write("cgroup no  accessible\n");
                std.os.exit(1);
            },
        };

        _ = try stdout.write("OOM Event Triggered\n");
    }
}
