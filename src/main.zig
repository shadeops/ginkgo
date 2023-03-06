const std = @import("std");

const oom_monitor = @import("oom_monitor.zig");
const GinkgoGroup = @import("GinkgoGroup.zig");
const MemInfo = @import("MemInfo.zig");

const one_gig = 1024 * 1024 * 1024;

var child_pid: ?std.os.pid_t = null;

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
            std.debug.print("Failed to kill child process [{}]\n", .{pid});
        };
        std.debug.print("Murdered {}\n", .{pid});
    }
}

const MemorySize = struct {
    rss: usize,
    swap: usize,

    fn total(self: MemorySize) usize {
        return self.rss + self.swap;
    }
};

fn computeLimits(
    allowed_limits: *const MemorySize,
    cgroup_limits: MemorySize,
    current_usage: MemorySize,
) !?MemorySize {
    const meminfo = try MemInfo.getMemInfo();

    var rss_limit_headroom = (allowed_limits.rss -| current_usage.rss);
    var rss_for_process = current_usage.rss + @min(rss_limit_headroom, meminfo.available);
    var rss = @max(current_usage.rss, rss_for_process);

    var swap_limit_headroom = (allowed_limits.swap -| current_usage.swap);
    var swap_for_process = current_usage.swap + @min(swap_limit_headroom, meminfo.swap_free);
    var swap = @max(current_usage.swap, swap_for_process);

    if (rss == cgroup_limits.rss and swap == cgroup_limits.swap) return null;
    return .{ .rss = rss, .swap = swap };
}

fn cgroupMemLimiter(
    cgroup: *const GinkgoGroup,
    user_limits: *const MemorySize,
    update_freq_ms: usize,
) !void {

    while (true) {
        // If we can't access the Cgroup it must be gone and can exit the loop.
        var mem_limit = cgroup.getCgroupValue("memory.limit_in_bytes") catch break;
        var memsw_limit = cgroup.getCgroupValue("memory.memsw.limit_in_bytes") catch break;
        var swap_allowance = memsw_limit -| mem_limit;
        const cgroup_limits = MemorySize{ .rss = mem_limit, .swap = swap_allowance };

        // this may be somewhat inaccurate, possibly use memory.stat or /proc/self/status
        var mem_usage = cgroup.getCgroupValue("memory.usage_in_bytes") catch break;
        var memsw_usage = cgroup.getCgroupValue("memory.memsw.usage_in_bytes") catch break;
        var swap_usage = memsw_usage -| mem_usage;
        const cgroup_usage = MemorySize{ .rss = mem_usage, .swap = swap_usage };

        var new_limit = try computeLimits(user_limits, cgroup_limits, cgroup_usage) orelse continue;

        if (new_limit.total() < memsw_limit) {
            cgroup.setCgroupValue(
                "memory.limit_in_bytes",
                new_limit.rss,
            ) catch |err| switch (err) {
                error.DeviceBusy => continue,
                else => break,
            };
            cgroup.setCgroupValue(
                "memory.memsw.limit_in_bytes",
                new_limit.total(),
            ) catch |err| switch (err) {
                error.DeviceBusy => continue,
                else => break,
            };
        } else {
            cgroup.setCgroupValue(
                "memory.memsw.limit_in_bytes",
                new_limit.total(),
            ) catch |err| switch (err) {
                error.DeviceBusy => continue,
                else => break,
            };
            cgroup.setCgroupValue(
                "memory.limit_in_bytes",
                new_limit.rss,
            ) catch |err| switch (err) {
                error.DeviceBusy => continue,
                else => break,
            };
        }
        std.time.sleep(std.time.ns_per_ms * update_freq_ms);
    }
    std.debug.print("cgroupMemLimiter stopped\n", .{});
}

pub fn runCgroup(allocator: std.mem.Allocator, user_limits: *MemorySize, active: bool, args: [][]const u8) !u8 {
    var ginkgo_group = try GinkgoGroup.init(allocator);
    defer ginkgo_group.deinit();

    try ginkgo_group.create();
    errdefer ginkgo_group.delete() catch {
        std.debug.print(
            "failed to delete cgroup: {s}\n",
            .{ginkgo_group.controller_path},
        );
    };

    // Since we are shrinking from the max defaults, memory goes before memsw
    try ginkgo_group.setCgroupValue("memory.limit_in_bytes", user_limits.rss);
    try ginkgo_group.setCgroupValue("memory.memsw.limit_in_bytes", user_limits.total());
    try ginkgo_group.setCgroupValue("memory.oom_control", 1);
    try ginkgo_group.setCgroupValue("memory.swappiness", 0);

    var oom_ctrl_thread = try std.Thread.spawn(.{}, oom_monitor.oomMonitor, .{&ginkgo_group, &child_pid});
    
    var cgroup_limiter_thread: ?std.Thread = null;
    if (active) {
        cgroup_limiter_thread = try std.Thread.spawn(
            .{},
            cgroupMemLimiter,
            .{ &ginkgo_group, user_limits, 500 },
        );
    }

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
                std.debug.print("stopped?\n", .{});
                continue;
            },
            .Unknown => |unk| {
                std.debug.print("Unknown return {}\n", .{unk});
                return error.UnknownReturn;
            },
        }
    };

    // deletion of the group causes threads to end
    ginkgo_group.delete() catch {
        std.debug.print(
            "failed to delete cgroup: {s}\n",
            .{ginkgo_group.controller_path},
        );
    };

    oom_ctrl_thread.join();
    if (cgroup_limiter_thread) |thread| {
        thread.join();
    }

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
    var active = false;
    
    while (true) {
        if (std.mem.eql(u8, cgroup_cmd[0], "-g")) {
            byte_limit = std.fmt.parseUnsigned(usize, cgroup_cmd[1], 10) catch {
                std.debug.print("Invalid option '{s}' for -g\n", .{cgroup_cmd[1]});
                return 1;
            };
            byte_limit *= one_gig;
            cgroup_cmd = cgroup_cmd[2..];
        } else if (std.mem.eql(u8, cgroup_cmd[0], "-a")) {
            active = true;
            cgroup_cmd = cgroup_cmd[1..];
        } else {
            break;
        }
    }

    var user_limits = MemorySize{ .rss = byte_limit, .swap = 0 };

    var ret = try runCgroup(allocator, &user_limits, active, cgroup_cmd);
    return ret;
}

// TODO
//  * If increasing memory, halt program so it doesn't start to swap between setting memsw and mem
