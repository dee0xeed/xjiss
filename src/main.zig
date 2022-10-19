
const std = @import("std");
const MessageDispatcher = @import("engine/message-queue.zig").MessageDispatcher;
const Jis = @import("synt.zig").Jis;
const Gui = @import("state-machines/gui.zig").XjisGui;
const Snd = @import("state-machines/snd.zig").XjisSound;
const MachinePool = @import("machine-pool.zig").MachinePool;
const Listener = @import("state-machines/listener.zig").Listener;
const Server = @import("state-machines/server.zig").Worker;
const Client = @import("state-machines/client.zig").Worker;

fn help() void {
    std.debug.print("Usage\n", .{});
    std.debug.print("Server mode: {s} s <port>\n", .{std.os.argv[0]});
    std.debug.print("Client mode: {s} c <host> <port>\n", .{std.os.argv[0]});
}

pub fn main() !void {

    if (1 == std.os.argv.len) {
        help();
        return;
    }
    if (0 != std.os.argv[1][1]) {
        help();
        return;
    }

    var allocator = std.heap.c_allocator;
    var md = try MessageDispatcher.onStack(allocator, 5);
    var jis = Jis.init();
    var mode: Gui.Mode = undefined;

    if (3 == std.os.argv.len) {
        // server mode
        if ('s' != std.os.argv[1][0]) {
            help();
            return;
        }
        const max_clients = 3;
        const arg2 = std.mem.sliceTo(std.os.argv[2], 0);
        const port = std.fmt.parseInt(u16, arg2, 10) catch 3333;
        var snd = try Snd.onHeap(allocator, &md, &jis);
        try snd.run();
        var i: u8 = 0;
        var pool = try MachinePool.init(allocator, max_clients);
        while (i < max_clients) : (i += 1) {
            var server = try Server.onHeap(allocator, &md, &pool, );
            try server.run();
        }
        var reception = try Listener.onHeap(allocator, &md, port, &pool);
        try reception.run();
        mode = .server;
    } else if (4 == std.os.argv.len) {
        // client mode
        if ('c' != std.os.argv[1][0]) {
            help();
            return;
        }
        const host = std.mem.sliceTo(std.os.argv[2], 0);
        const arg3 = std.mem.sliceTo(std.os.argv[3], 0);
        const port = std.fmt.parseInt(u16, arg3, 10) catch 3333;
        var client = try Client.onHeap(allocator, &md, host, port);
        try client.run();
        mode = .client;
    } else {
        help();
        return;
    }

    var gui = try Gui.onHeap(allocator, &md, &jis, mode);
    try gui.run();
    try md.loop();
    md.eq.fini();
}
