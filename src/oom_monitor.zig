const std = @import("std");
const GinkgoGroup = @import("GinkgoGroup.zig");

const ui = @import("ui.zig");

pub fn oomMonitor(cgroup: *const GinkgoGroup, pid: *const ?std.os.pid_t) !void {

    ui.initUI();

    var event_ctrl_buffer: [256]u8 = undefined;
    var oom_ctrl_buffer: [256]u8 = undefined;

    const event_ctrl_path = try std.fmt.bufPrint(
        &event_ctrl_buffer,
        "{s}/{s}",
        .{ cgroup.cgroup_path, "cgroup.event_control" },
    );
    const oom_ctrl_path = try std.fmt.bufPrint(
        &oom_ctrl_buffer,
        "{s}/{s}",
        .{ cgroup.cgroup_path, "memory.oom_control" },
    );

    var event_ctrl_fd = try std.fs.openFileAbsolute(event_ctrl_path, .{ .mode = .write_only });
    defer event_ctrl_fd.close();

    var oom_ctrl_fd = try std.fs.openFileAbsolute(oom_ctrl_path, .{ .mode = .read_only });
    defer oom_ctrl_fd.close();

    const efd = try std.os.eventfd(0, 0);
    defer std.os.close(efd);

    var line_buffer = [_]u8{0} ** 128;
    var line = try std.fmt.bufPrint(&line_buffer, "{d} {d}\x00", .{ efd, oom_ctrl_fd.handle });
    _ = try event_ctrl_fd.write(line);

    var result_buf: [@sizeOf(u64)]u8 = undefined;
    while (true) {
        var ret = try std.os.read(efd, &result_buf);
        std.debug.assert(ret == @sizeOf(@TypeOf(result_buf)));

        std.fs.accessAbsolute(event_ctrl_path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("cgroup deleted\n", .{});
                break;
            },
            else => {
                std.debug.print("cgroup not accessible\n", .{});
                return;
            },
        };

        std.debug.print("OOM Event Triggered\n", .{});
        switch (ui.promptUI()) {
            .ignore => continue,
            .kill => {
                if (pid.*) |p| try std.os.kill(p, 9);
                break;
            },
            .kill_save => {
                if (pid.*) |p| try std.os.kill(p, 11);
                // provide some RAM to terminate
                break;
            },
            .swap => {
                continue;
            },
            .swap_all => {
                continue;
            },
        }
    }
}
