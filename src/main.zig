const std = @import("std");

const ray = @cImport({
    @cInclude("raygui.h");
    @cInclude("raylib.h");
});

fn initUI() void {
    ray.SetTraceLogLevel(0);
    ray.SetConfigFlags(ray.FLAG_WINDOW_HIDDEN);
    ray.InitWindow(400, 300, "ginkgo");
    ray.SetTargetFPS(30);
    //ray.GuiLoadStyleDark();
    //ray.GuiSetStyle(ray.DEFAULT, ray.TEXT_SIZE, 20);
}

fn promptUI() void {

    ray.ClearWindowState(ray.FLAG_WINDOW_HIDDEN);
    ray.SetWindowState(ray.FLAG_WINDOW_TOPMOST);
    defer ray.ClearWindowState(ray.FLAG_WINDOW_TOPMOST);
    defer ray.SetWindowState(ray.FLAG_WINDOW_HIDDEN);
    ray.RestoreWindow();

    var ram: f32 = 50.0;
    var iram: i32 = 50;
    var edit = false;

    while (!ray.WindowShouldClose()) {
        ray.BeginDrawing();
        defer ray.EndDrawing();

        //ray.ClearBackground(.{ .r = 64, .g = 50, .b = 59, .a = 255 });
        ram = ray.GuiSliderBar(.{.x=35, .y=5, .width=100, .height=20}, "RAM", null, ram, 0.0, 100.0);
        var pressed = ray.GuiValueBox(.{.x=135, .y=5, .width=40, .height=20}, null, &iram, 0, 100, edit);
        if (ray.GuiButton(.{.x=35, .y=25, .width=100, .height=20}, "Allow Swap")) {
            break;
        }

        if (pressed and edit == false) {
            edit = true;
        } else if (pressed and edit == true) {
            ram = @intToFloat(f32, iram);
            edit = false;
        } else if (edit == false) { 
            iram = @floatToInt(i32, ram);
        }
    }
}

pub fn main() !void {
    initUI();
    defer ray.CloseWindow();

    std.debug.print("Window 1\n", .{});
    promptUI();
    std.debug.print("Window 2\n", .{});
    promptUI();
    std.debug.print("Window 3\n", .{});
}


test "simple test" {
    var list = std.ArrayList(i32).init(std.testing.allocator);
    defer list.deinit(); // try commenting this out and see if zig detects the memory leak!
    try list.append(42);
    try std.testing.expectEqual(@as(i32, 42), list.pop());
}
