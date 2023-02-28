const std = @import("std");

const MemInfo = struct {
    total: usize,
    free: usize,
    available: usize,
    cached: usize,
    swap_total: usize,
    swap_free: usize,
};

pub fn getMemInfo() !MemInfo {
    var line_buf: [1024]u8 = undefined;

    var meminfo_handle = try std.fs.openFileAbsolute("/proc/meminfo", .{});
    defer meminfo_handle.close();

    var reader = meminfo_handle.reader();
    var meminfo: MemInfo = undefined;
    while (try reader.readUntilDelimiterOrEof(&line_buf, '\n')) |line| {
        var tokens = std.mem.tokenize(u8, line, " ");
        var entry = tokens.next() orelse continue;
        var value_str = tokens.next() orelse continue;
        var value = try std.fmt.parseUnsigned(usize, value_str, 10);
        // meminfo is in kB
        value *= 1024;
        if (std.mem.eql(u8, entry, "MemTotal:")) {
            meminfo.total = value;
        } else if (std.mem.eql(u8, entry, "MemFree:")) {
            meminfo.free = value;
        } else if (std.mem.eql(u8, entry, "MemAvailable:")) {
            meminfo.available = value;
        } else if (std.mem.eql(u8, entry, "Cached:")) {
            meminfo.cached = value;
        } else if (std.mem.eql(u8, entry, "SwapTotal:")) {
            meminfo.swap_total = value;
        } else if (std.mem.eql(u8, entry, "SwapFree:")) {
            meminfo.swap_free = value;
        }
    }
    return meminfo;
}

const GinkgoGroup = struct {
    const cgroup_fs = "/sys/fs/cgroup";

    oom_control: bool = true,
    swappiness: u8 = 0,
    swap_limit: usize = 0,
    memory_limit: usize,

    cgroup_name: []const u8,
    cgroup_path: []const u8,
    controller_path: []const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, memory_limit: usize) !GinkgoGroup {
        const this_pid = std.os.system.getpid();
        const cgroup_name = try std.fmt.allocPrint(allocator, "ginkgo_{}", .{this_pid});
        errdefer allocator.free(cgroup_name);
        const cgroup_path = try std.fmt.allocPrint(
            allocator,
            "{s}/memory/ginkgo/{s}",
            .{ cgroup_fs, cgroup_name },
        );
        errdefer allocator.free(cgroup_path);

        const controller_path = try std.fmt.allocPrint(allocator, "memory:ginkgo/{s}", .{cgroup_name});
        errdefer allocator.free(controller_path);

        return .{
            .memory_limit = memory_limit,
            .cgroup_name = cgroup_name,
            .cgroup_path = cgroup_path,
            .controller_path = controller_path,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *GinkgoGroup) void {
        self.allocator.free(self.cgroup_name);
        self.allocator.free(self.cgroup_path);
        self.allocator.free(self.controller_path);
    }

    pub fn create(self: GinkgoGroup) !void {
        var args: [3][]const u8 = .{ "cgcreate", "-g", self.controller_path };

        var proc = std.ChildProcess.init(&args, self.allocator);
        var ret = try proc.spawnAndWait();
        switch (ret) {
            .Exited => |code| {
                if (code != 0) return error.CgroupCreateFailed;
            },
            else => return error.CgroupCreateFailed,
        }
    }

    pub fn delete(self: GinkgoGroup) !void {
        var args: [2][]const u8 = .{ "cgdelete", self.controller_path };

        var proc = std.ChildProcess.init(&args, self.allocator);
        var ret = try proc.spawnAndWait();
        switch (ret) {
            .Exited => |code| {
                if (code != 0) return error.CgroupDeleteFailed;
            },
            else => return error.CgroupDeleteFailed,
        }
    }

    pub fn getCgroupValue(self: GinkgoGroup, control_file: []const u8) !usize {
        // TODO: This might be too small for memory.stat
        var buffer: [1024]u8 = undefined;
        var buf_allocator = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = buf_allocator.allocator();

        var path = try std.mem.join(allocator, "/", &.{ self.cgroup_path, control_file });
        std.debug.print("{s}\n", .{path});
        var handle = try std.fs.openFileAbsolute(path, .{});
        defer handle.close();

        // ignore the trailing byte (\n)
        var num_bytes = try handle.readAll(&buffer) - 1;
        return try std.fmt.parseUnsigned(usize, buffer[0..num_bytes], 10);
    }

    pub fn setCgroupValue(self: GinkgoGroup, control_file: []const u8, value: usize) !void {
        var buffer: [256]u8 = undefined;
        var buf_allocator = std.heap.FixedBufferAllocator.init(&buffer);
        const allocator = buf_allocator.allocator();

        var path = try std.mem.join(allocator, "/", &.{ self.cgroup_path, control_file });
        var handle = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
        defer handle.close();

        var value_str = try std.fmt.bufPrint(&buffer, "{}", .{value});
        _ = try handle.write(value_str);
        return;
    }
};

pub fn oomControl(cgroup: *const GinkgoGroup) !void {
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

    var line_buffer = [_]u8{0} ** 128;
    var line = try std.fmt.bufPrint(&line_buffer, "{d} {d}\x00", .{ efd, oom_ctrl_fd.handle });
    _ = try event_ctrl_fd.write(line);

    var current_limit = try cgroup.getCgroupValue("memory.limit_in_bytes");

    var result_buf: [@sizeOf(u64)]u8 = undefined;
    const inc = 1024 * 1024 * 1024 * 2;
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
        if (current_limit < cgroup.memory_limit) {
            current_limit = @min(current_limit + inc, cgroup.memory_limit);
            // When increasing, memsw has to go first.
            try cgroup.setCgroupValue("memory.memsw.limit_in_bytes", current_limit);
            try cgroup.setCgroupValue("memory.limit_in_bytes", current_limit);
        } else {
            std.debug.print("Halting\n", .{});
        }
    }
}

pub fn runCgroup(allocator: std.mem.Allocator, byte_limit: usize, args: [][]const u8) !void {
    var ginkgo_group = try GinkgoGroup.init(allocator, byte_limit);
    defer ginkgo_group.deinit();

    try ginkgo_group.create();

    // TODO: This is dangerous, the only way for this thread to end is if the
    // cgroup is deleted which makes order matter. Better to store state in
    // the GinkgoGroup
    var oom_ctrl_thread = try std.Thread.spawn(.{}, oomControl, .{&ginkgo_group});
    defer oom_ctrl_thread.join();

    defer ginkgo_group.delete() catch {
        std.debug.print(
            "failed to delete cgroup: {s}\n",
            .{ginkgo_group.controller_path},
        );
    };

    // 4GB
    const start_limit = 1024 * 1024 * 1024 * 4;

    //try ginkgo_group.setCgroupValue("memory.swappiness", 0);
    try ginkgo_group.setCgroupValue("memory.limit_in_bytes", start_limit);
    try ginkgo_group.setCgroupValue("memory.memsw.limit_in_bytes", start_limit);
    try ginkgo_group.setCgroupValue("memory.oom_control", 1);

    var cgexec_args = try allocator.alloc([]const u8, args.len + 3);
    defer allocator.free(cgexec_args);

    cgexec_args[0] = "cgexec";
    cgexec_args[1] = "-g";
    cgexec_args[2] = ginkgo_group.controller_path;
    for (cgexec_args[3..], args[0..]) |*cgarg, arg| {
        cgarg.* = arg;
    }

    var proc = std.ChildProcess.init(cgexec_args, allocator);
    var ret = try proc.spawnAndWait();
    switch (ret) {
        .Exited => |code| {
            if (code != 0) return error.CgroupCreateFailed;
        },
        else => return error.CgroupCreateFailed,
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        _ = gpa.deinit();
    }
    const allocator = gpa.allocator();

    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const meminfo = try getMemInfo();

    var cgroup_cmd = args[1..];

    var byte_limit = meminfo.total;
    if (args.len > 3 and std.mem.eql(u8, args[1], "-g")) {
        byte_limit = std.fmt.parseUnsigned(usize, args[2], 10) catch {
            std.debug.print("Invalid option '{s}' for -g\n", .{args[2]});
            return;
        };
        byte_limit *= 1024 * 1024 * 1024;
        cgroup_cmd = args[3..];
    }

    try runCgroup(allocator, byte_limit, cgroup_cmd);
}
