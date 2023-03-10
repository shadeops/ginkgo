const std = @import("std");
const builtin = @import("builtin");

const cgroup_fs = "/sys/fs/cgroup";

const GinkgoGroup = @This();

cgroup_name: []const u8,
cgroup_path: []const u8,
controller_path: []const u8,

allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !GinkgoGroup {
    if (builtin.target.os.tag != .linux)
        @compileError("Unsupported operating system " ++ @tagName(builtin.target.os.tag));

    const this_pid = std.os.linux.getpid();
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
    try std.fs.makeDirAbsolute(self.cgroup_path);
}

pub fn delete(self: GinkgoGroup) !void {
    try std.fs.deleteDirAbsolute(self.cgroup_path);
}

pub fn getCgroupValue(self: GinkgoGroup, control_file: []const u8) !usize {
    // TODO: This might be too small for memory.stat
    var buffer: [1024]u8 = undefined;
    var buf_allocator = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = buf_allocator.allocator();

    var path = try std.mem.join(allocator, "/", &.{ self.cgroup_path, control_file });
    var handle = try std.fs.openFileAbsolute(path, .{});
    defer handle.close();

    // ignore the trailing byte (\n)
    var num_bytes = try handle.readAll(&buffer) - 1;
    return try std.fmt.parseUnsigned(usize, buffer[0..num_bytes], 10);
}

pub fn setCgroupValue(self: GinkgoGroup, control_file: []const u8, value: usize) !void {
    var buffer: [1024]u8 = undefined;
    var buf_allocator = std.heap.FixedBufferAllocator.init(&buffer);
    const allocator = buf_allocator.allocator();

    var path = try std.mem.join(allocator, "/", &.{ self.cgroup_path, control_file });
    var handle = try std.fs.openFileAbsolute(path, .{ .mode = .write_only });
    defer handle.close();
    var value_str = try std.fmt.bufPrint(&buffer, "{}", .{value});
    _ = try handle.write(value_str);
    return;
}
