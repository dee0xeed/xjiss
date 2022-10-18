
const std = @import("std");
const MessageDispatcher = @import("engine/message-queue.zig").MessageDispatcher;
const Jis = @import("synt.zig").Jis;
const Gui = @import("state-machines/gui.zig").XjisGui;
const Snd = @import("state-machines/snd.zig").XjisSound;

pub fn main() !void {

    var allocator = std.heap.c_allocator;
    var md = try MessageDispatcher.onStack(allocator, 5);

    var jis = Jis.init();
    var snd = try Snd.onHeap(allocator, &md, &jis);
    var gui = try Gui.onHeap(allocator, &md, &jis);

    try snd.run();
    try gui.run();
    try md.loop();
    md.eq.fini();
}
