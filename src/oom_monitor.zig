const std = @import("std");

const main = @import("main.zig");
const MemInfo = @import("MemInfo.zig");
const GinkgoGroup = @import("GinkgoGroup.zig");
const ui = @import("ui.zig");

const buffer_size = 128;

pub fn oomMonitor(ctx: *const main.Context) !void {
    const meminfo = try MemInfo.getMemInfo();

    ui.initUI();

    var event_ctrl_buffer = [_]u8{0} ** buffer_size;
    var oom_ctrl_buffer = [_]u8{0} ** buffer_size;
    var line_buffer = [_]u8{0} ** buffer_size;

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

    var event_ctrl_fd = std.fs.openFileAbsolute(event_ctrl_path, .{ .mode = .write_only }) catch {
        std.log.err("Could not open {s}.", .{event_ctrl_path});
        return;
    };
    defer event_ctrl_fd.close();

    var oom_ctrl_fd = std.fs.openFileAbsolute(oom_ctrl_path, .{ .mode = .read_only }) catch {
        std.log.err("Could not open {s}.", .{oom_ctrl_path});
        return;
    };
    defer oom_ctrl_fd.close();

    const efd = std.os.eventfd(0, 0) catch {
        std.log.err("Could not create event file descriptor", .{});
        return;
    };
    defer std.os.close(efd);

    var line = try std.fmt.bufPrint(&line_buffer, "{d} {d}\x00", .{ efd, oom_ctrl_fd.handle });
    _ = try event_ctrl_fd.write(line);

    var result_buf: [@sizeOf(u64)]u8 = undefined;
    while (true) {
        var ret = try std.os.read(efd, &result_buf);
        std.debug.assert(ret == @sizeOf(@TypeOf(result_buf)));

        std.fs.accessAbsolute(event_ctrl_path, .{ .mode = .write_only }) catch |err| switch (err) {
            error.FileNotFound => {
                std.log.debug("Cgroup, {s}, was deleted.", .{event_ctrl_path});
                break;
            },
            else => {
                std.log.debug("Cgroup, {s}, not accessible.", .{event_ctrl_path});
                break;
            },
        };

        std.log.debug("OOM Monitor Triggered", .{});
        switch (ui.promptUI()) {
            .ignore => continue,
            .kill => {
                if (main.child_pid) |p| {
                    std.log.debug("Killing {} with signal 9", .{p});
                    std.os.kill(p, 9) catch |err| {
                        std.log.warn("Failed to kill 9 {}, {}", .{p, err});
                    };
                }
                break;
            },
            .kill_save => {
                ctx.mutex.lock();
                defer {
                    ctx.condition.signal();
                    ctx.mutex.unlock();
                }
                if (main.child_pid) |p| {
                    std.log.debug("Killing {} with signal 11", .{p});
                    std.os.kill(p, 11) catch |err| {
                        std.log.warn("Failed to kill 11 {}, {}", .{p, err});
                    };
                }
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
                ctx.limits.swap += @min(2 * 1024 * 1024 * 1024, meminfo.swap_total);
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
    std.log.debug("oomMonitor thread has stopped", .{});
}
