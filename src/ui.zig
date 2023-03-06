const ray = @cImport({
    @cInclude("raylib.h");
    @cInclude("raygui.h");
});

const window_size_x = 400;
const window_size_y = 320;
const panel_height = 125;
const btn_size_x = 100;
const btn_size_y = 25;
const panel_pad = 10;
const lbl_size_x = window_size_x - (btn_size_x + panel_pad * 3);

const warning_txt =
    \\Your process has run out of RAM and will start to SWAP.
    \\Swapping can significantly slow down your computer.
    \\
    \\To prevent this from happening your process has been
    \\stopped by Ginkgo.
    \\
    \\Please select an option on how to proceed.
;

pub fn initUI() void {
    ray.SetTraceLogLevel(0);
    ray.SetConfigFlags(ray.FLAG_WINDOW_HIDDEN);
    ray.InitWindow(window_size_x, window_size_y, "Ginkgo Swap Guard");
    ray.SetTargetFPS(30);
    //GuiLoadStyleDark();
}

pub fn promptUI() void {
    ray.ClearWindowState(ray.FLAG_WINDOW_HIDDEN);
    ray.SetWindowState(ray.FLAG_WINDOW_TOPMOST);
    defer ray.ClearWindowState(ray.FLAG_WINDOW_TOPMOST);
    defer ray.SetWindowState(ray.FLAG_WINDOW_HIDDEN);
    ray.RestoreWindow();

    var c_panel = ray.Rectangle{
        .x = 0,
        .y = 0,
        .width = window_size_x,
        .height = window_size_y,
    };

    var c_group_box = c_panel;
    c_group_box.height = panel_height;
    c_group_box.x += panel_pad;
    c_group_box.y += panel_pad;
    c_group_box.width -= panel_pad * 2;

    var c_text_box = c_group_box;
    c_text_box.y += panel_pad;
    var text_box_txt: [warning_txt.len]u8 = warning_txt.*;

    var c_kill_btn = ray.Rectangle{
        .x = panel_pad,
        .y = c_group_box.y + c_group_box.height + panel_pad,
        .width = btn_size_x,
        .height = btn_size_y,
    };
    var c_kill_lbl = c_kill_btn;
    c_kill_lbl.x += c_kill_btn.width + panel_pad;
    c_kill_lbl.width = lbl_size_x;

    var c_kill_save_btn = c_kill_btn;
    c_kill_save_btn.y += c_kill_btn.height + panel_pad;
    var c_kill_save_lbl = c_kill_save_btn;
    c_kill_save_lbl.x += c_kill_save_btn.width + panel_pad;
    c_kill_save_lbl.width = lbl_size_x;

    var c_swap_btn = c_kill_save_btn;
    c_swap_btn.y += c_kill_save_btn.height + panel_pad;
    var c_swap_lbl = c_swap_btn;
    c_swap_lbl.x += c_swap_btn.width + panel_pad;
    c_swap_lbl.width = lbl_size_x;

    var c_swap_all_btn = c_swap_btn;
    c_swap_all_btn.y += c_swap_btn.height + panel_pad;
    var c_swap_all_lbl = c_swap_all_btn;
    c_swap_all_lbl.x += c_swap_all_btn.width + panel_pad;
    c_swap_all_lbl.width = lbl_size_x;

    var c_also_lbl = c_swap_all_btn;
    c_also_lbl.y += c_swap_all_btn.height + panel_pad;
    c_also_lbl.width = c_panel.width - panel_pad * 2;

    while (!ray.WindowShouldClose()) {
        ray.BeginDrawing();
        defer ray.EndDrawing();

        ray.GuiLock();
        ray.GuiPanel(c_panel, null);
        ray.GuiGroupBox(c_group_box, "Warning");
        ray.GuiSetStyle(ray.TEXTBOX, ray.BORDER_WIDTH, 0);
        ray.GuiSetStyle(ray.TEXTBOX, ray.TEXT_INNER_PADDING, 8);
        _ = ray.GuiTextBoxMulti(c_text_box, &text_box_txt, 1, false);
        ray.GuiUnlock();

        var kill = ray.GuiButton(c_kill_btn, "Kill");
        ray.GuiLabel(c_kill_lbl, "Force kill the process immediately. (kill -9)");

        var kill_save = ray.GuiButton(c_kill_save_btn, "Kill & Save");
        ray.GuiLabel(c_kill_save_lbl, "Kill the process, attempt crash file. (kill -11)");

        var swap = ray.GuiButton(c_swap_btn, "Allow 2G of SWAP");
        ray.GuiLabel(c_swap_lbl, "Your process will unfreeze but start to swap.\nGinkgo may triggered again if provided SWAP used.");

        var swap_all = ray.GuiButton(c_swap_all_btn, "Allow all of SWAP");
        ray.GuiLabel(c_swap_all_lbl, "Disables Ginkgo, all Swap may be used.");

        ray.GuiLabel(c_also_lbl, "Alternatively, you may close other processes in order to free up RAM.\nDoing so will unfreeze your process.");

        if (kill or kill_save or swap or swap_all) break;
    }
}
