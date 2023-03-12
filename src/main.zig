const std = @import("std");

const oom_monitor = @import("oom_monitor.zig");
const GinkgoGroup = @import("GinkgoGroup.zig");
const MemInfo = @import("MemInfo.zig");

const one_gig = 1024 * 1024 * 1024;

pub var child_pid: ?std.os.pid_t = null;

// Note: If we Ctrl+C in the shell, it sends a SIGINT to the entire process group.
//  meaning our child process is interrupted and our cgroup is cleaned up, however
//  this is not the case for a killall -INT ginkgo
const handled_signals = [_]c_int{
    std.os.SIG.INT,
    std.os.SIG.TERM,
};

pub fn sig_handler(sig: c_int) align(1) callconv(.C) void {
    if (child_pid) |pid| {
        std.os.kill(pid, @intCast(u8, sig)) catch {
            std.log.warn("Failed to kill child process [{}].", .{pid});
        };
        std.log.info("Pid {} has been killed with signal {}.", .{pid, @intCast(u8, sig)});
    }
}

pub const MemorySize = struct {
    rss: usize,
    swap: usize,

    fn total(self: MemorySize) usize {
        return self.rss + self.swap;
    }
};

pub const Context = struct {
    cgroup: *const GinkgoGroup,
    mutex: *std.Thread.Mutex,
    condition: *std.Thread.Condition,
    limits: MemorySize,
    done: bool = false,
};

fn computeLimits(
    allowed_limits: MemorySize,
    current_usage: MemorySize,
) !MemorySize {
    const meminfo = try MemInfo.getMemInfo();

    var rss_limit_headroom = (allowed_limits.rss -| current_usage.rss);
    var rss_for_process = current_usage.rss + @min(rss_limit_headroom, meminfo.available);
    var rss = @max(current_usage.rss, rss_for_process);

    var swap_limit_headroom = (allowed_limits.swap -| current_usage.swap);
    var swap_for_process = current_usage.swap + @min(swap_limit_headroom, meminfo.swap_free);
    var swap = @max(current_usage.swap, swap_for_process);

    return .{ .rss = rss, .swap = swap };
}

fn cgroupMemLimiter(
    ctx: *const Context,
    update_freq_ms: ?usize,
) !void {

    var swappiness = ctx.limits.swap > 0;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    while (!ctx.done) {

        if (update_freq_ms) |timeout| {
            ctx.condition.timedWait(ctx.mutex, timeout*std.time.ns_per_ms) catch {};
        } else {
            ctx.condition.wait(ctx.mutex);
        }

        // If we can't access the Cgroup it must be gone and can exit the loop.
        var mem_limit = ctx.cgroup.getCgroupValue("memory.limit_in_bytes") catch break;
        var memsw_limit = ctx.cgroup.getCgroupValue("memory.memsw.limit_in_bytes") catch break;
        var swap_allowance = memsw_limit -| mem_limit;
        const cgroup_limits = MemorySize{ .rss = mem_limit, .swap = swap_allowance };

        // this may be somewhat inaccurate, possibly use memory.stat or /proc/self/status
        var mem_usage = ctx.cgroup.getCgroupValue("memory.usage_in_bytes") catch break;
        var memsw_usage = ctx.cgroup.getCgroupValue("memory.memsw.usage_in_bytes") catch break;
        var swap_usage = memsw_usage -| mem_usage;
        const cgroup_usage = MemorySize{ .rss = mem_usage, .swap = swap_usage };

        var new_limit = try computeLimits(ctx.limits, cgroup_usage);

        var new_swappiness = ctx.limits.swap > 0;
        defer swappiness = new_swappiness;
        if (new_swappiness != swappiness) {
            if (new_swappiness) {
                try ctx.cgroup.setCgroupValue("memory.swappiness", 60);
            } else {
                try ctx.cgroup.setCgroupValue("memory.swappiness", 0);
            }
        }

        var limit_diff = @intCast(i64, new_limit.total()) - @intCast(i64, cgroup_limits.total());
        if (try std.math.absInt(limit_diff) < one_gig) continue;

        if (new_limit.total() < memsw_limit) {
            ctx.cgroup.setCgroupValue(
                "memory.limit_in_bytes",
                new_limit.rss,
            ) catch |err| switch (err) {
                error.DeviceBusy => continue,
                else => break,
            };
            ctx.cgroup.setCgroupValue(
                "memory.memsw.limit_in_bytes",
                new_limit.total(),
            ) catch |err| switch (err) {
                error.DeviceBusy => continue,
                else => break,
            };
        } else {
            ctx.cgroup.setCgroupValue(
                "memory.memsw.limit_in_bytes",
                new_limit.total(),
            ) catch |err| switch (err) {
                error.DeviceBusy => continue,
                else => break,
            };
            ctx.cgroup.setCgroupValue(
                "memory.limit_in_bytes",
                new_limit.rss,
            ) catch |err| switch (err) {
                error.DeviceBusy => continue,
                else => break,
            };
        }
    }
    std.log.debug("cgroupMemLimiter thread has stopped.", .{});
}

pub fn runCgroup(allocator: std.mem.Allocator, user_limits: MemorySize, update_ms: ?u64, args: [][]const u8) !u8 {
    var ginkgo_group = try GinkgoGroup.init(allocator);
    defer ginkgo_group.deinit();

    try ginkgo_group.create();
    errdefer ginkgo_group.delete() catch {
        std.log.warn(
            "Failed to delete cgroup: {s}.",
            .{ginkgo_group.controller_path},
        );
    };

    var mutex = std.Thread.Mutex{};
    var condition = std.Thread.Condition{};

    var ctx = Context{
        .cgroup = &ginkgo_group,
        .mutex = &mutex,
        .condition = &condition,
        .limits = user_limits,
    };

    // Since we are shrinking from the max defaults, memory goes before memsw
    try ginkgo_group.setCgroupValue("memory.limit_in_bytes", ctx.limits.rss);
    try ginkgo_group.setCgroupValue("memory.memsw.limit_in_bytes", ctx.limits.total());
    try ginkgo_group.setCgroupValue("memory.oom_control", 1);
    try ginkgo_group.setCgroupValue("memory.swappiness", 0);

    var oom_ctrl_thread = try std.Thread.spawn(.{}, oom_monitor.oomMonitor, .{ &ctx });
    var cgroup_limiter_thread = try std.Thread.spawn(.{}, cgroupMemLimiter, .{ &ctx, update_ms });

    var cgexec_args = try allocator.alloc([]const u8, args.len + 3);
    defer allocator.free(cgexec_args);

    const sig_action = std.os.Sigaction{
        .handler = .{ .handler = sig_handler },
        .mask = std.os.empty_sigset,
        .flags = 0,
    };
    for (&handled_signals) |signal| {
        try std.os.sigaction(@intCast(u6, signal), &sig_action, null);
    }

    cgexec_args[0] = "cgexec";
    cgexec_args[1] = "-g";
    cgexec_args[2] = ginkgo_group.controller_path;
    for (cgexec_args[3..], args[0..]) |*cgarg, arg| {
        cgarg.* = arg;
    }

    var proc = std.ChildProcess.init(cgexec_args, allocator);
    try proc.spawn();
    child_pid = proc.id;
    defer child_pid = null;

    var ret_code: u8 = brk: while (true) {
        switch (try proc.wait()) {
            .Exited => |code| break :brk code,
            .Signal => |sig| break :brk 128 + @truncate(u8, sig),
            .Stopped => |_| {
                std.log.warn("Process was stopped and not handled.", .{});
                continue;
            },
            .Unknown => |unk| {
                std.log.err("Unknown Term, {}, from process {?}.", .{unk, child_pid});
                return error.UnknownReturn;
            },
        }
    };

    {
        ctx.mutex.lock();
        defer ctx.mutex.unlock();
        ctx.done = true;
        ctx.condition.broadcast();

        // deletion of the group causes threads to end
        ginkgo_group.delete() catch {
            std.log.warn(
                "Failed to delete cgroup: {s}",
                .{ginkgo_group.controller_path},
            );
        };
    }

    oom_ctrl_thread.join();
    cgroup_limiter_thread.join();

    return ret_code;
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var cgroup_cmd = args[1..];

    const meminfo = try MemInfo.getMemInfo();
    var byte_limit = meminfo.total - one_gig;
    var update_ms: ?u64 = 1000;

    while (true) {
        if (std.mem.eql(u8, cgroup_cmd[0], "-g")) {
            byte_limit = std.fmt.parseUnsigned(usize, cgroup_cmd[1], 10) catch {
                std.log.err("Invalid option '{s}' for -g.", .{cgroup_cmd[1]});
                return 1;
            };
            byte_limit *= one_gig;
            cgroup_cmd = cgroup_cmd[2..];
        } else if (std.mem.eql(u8, cgroup_cmd[0], "-p")) {
            update_ms = null;
            cgroup_cmd = cgroup_cmd[1..];
        } else {
            break;
        }
    }

    const user_limits = MemorySize{ .rss = byte_limit, .swap = 0 };

    var ret = try runCgroup(allocator, user_limits, update_ms, cgroup_cmd);
    return ret;
}

// TODO
//  * If increasing memory, halt program so it doesn't start to swap between setting memsw and mem
