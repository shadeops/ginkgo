const std = @import("std");
const MemInfo = @import("MemInfo.zig");
const GinkgoGroup = @import("GinkgoGroup.zig");

const main = @import("main.zig");
const Context = main.Context;

const ui = @import("ui.zig");

pub fn oomMonitor(ctx: *Context) !void {
    const meminfo = try MemInfo.getMemInfo();

    ui.initUI();

    var event_ctrl_buffer: [256]u8 = undefined;
    var oom_ctrl_buffer: [256]u8 = undefined;

    const event_ctrl_path = try std.fmt.bufPrint(
        &event_ctrl_buffer,
        "{s}/{s}",
        .{ ctx.cgroup.cgroup_path, "cgroup.event_control" },
    );
    const oom_ctrl_path = try std.fmt.bufPrint(
        &oom_ctrl_buffer,
        "{s}/{s}",
        .{ ctx.cgroup.cgroup_path, "memory.oom_control" },
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
                std.log.debug("Cgroup, {s}, deleted.", .{event_ctrl_path});
                break;
            },
            else => {
                std.log.debug("Cgroup, {s}, not accessible.", .{event_ctrl_path});
                return;
            },
        };

        switch (ui.promptUI()) {
            .ignore => continue,
            .kill => {
                if (main.child_pid) |p| try std.os.kill(p, 9);
                break;
            },
            .kill_save => {
                ctx.mutex.lock();
                defer {
                    ctx.condition.signal();
                    ctx.mutex.unlock();
                }
                if (main.child_pid) |p| try std.os.kill(p, 11);
                ctx.limits.rss = meminfo.total;
                ctx.limits.swap = meminfo.swap_total;
                break;
            },
            .swap => {
                ctx.mutex.lock();
                defer {
                    ctx.condition.signal();
                    ctx.mutex.unlock();
                }
                ctx.limits.swap += @min(2*1024*1024*1024, meminfo.swap_total);
                continue;
            },
            .swap_all => {
                ctx.mutex.lock();
                defer {
                    ctx.condition.signal();
                    ctx.mutex.unlock();
                }
                ctx.limits.swap = meminfo.swap_total;
                break;
            },
        }
    }
}
