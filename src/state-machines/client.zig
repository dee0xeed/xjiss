
const std = @import("std");
const os = std.os;
const mem = std.mem;
const net = std.net;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const mq = @import("../engine/message-queue.zig");
const MessageDispatcher = mq.MessageDispatcher;
const MessageQueue = MessageDispatcher.MessageQueue;
const Message = MessageQueue.Message;

const esrc = @import("../engine//event-sources.zig");
const EventSource = esrc.EventSource;

const edsm = @import("../engine/edsm.zig");
const StageMachine = edsm.StageMachine;
const Stage = StageMachine.Stage;
const Reflex = Stage.Reflex;

const MachinePool = @import("../machine-pool.zig").MachinePool;
const util = @import("../util.zig");

pub const Worker = struct {

    const M0_CONN = Message.M0;
    const M0_WORK = Message.M0;
    const M1_WAIT = Message.M1;

    const WorkerData = struct {
        tm: EventSource,
        io: EventSource,
        host: []const u8,
        port: u16,
        addr: net.Address,
        buf: [16]u8,
        cnt: usize,
    };

    pub fn onHeap (
        a: Allocator,
        md: *MessageDispatcher,
        host: []const u8,
        port: u16,
    ) !*StageMachine {

        var me = try StageMachine.onHeap(a, md, "WORKER", 1);
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "CONN", .enter = &connEnter, .leave = null});
        try me.addStage(Stage{.name = "WORK", .enter = null, .leave = null});
        try me.addStage(Stage{.name = "WAIT", .enter = &waitEnter, .leave = null});

        var init = &me.stages.items[0];
        var conn = &me.stages.items[1];
        var work = &me.stages.items[2];
        var wait = &me.stages.items[3];

        init.setReflex(.sm, Message.M0, .{.transition = conn});

        conn.setReflex(.io, Message.D1, .{.action = &connD1});
        conn.setReflex(.io, Message.D2, .{.action = &connD2});
        conn.setReflex(.sm, Message.M0, .{.transition = work});
        conn.setReflex(.sm, Message.M1, .{.transition = wait});

        work.setReflex(.sm, Message.M0, .{.action = &workM0});
        work.setReflex(.io, Message.D1, .{.action = &workD1});
        work.setReflex(.io, Message.D2, .{.action = &workD2});
        work.setReflex(.sm, Message.M1, .{.transition = wait});

        wait.setReflex(.tm, Message.T0, .{.transition = conn});
        wait.setReflex(.sm, Message.M0, .{.action = &waitM0});

        me.data = me.allocator.create(WorkerData) catch unreachable;
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.host = host;
        wd.port = port;
        wd.cnt = 0;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.io = EventSource.init(me, .io, .csock, Message.D0);
        me.initTimer(&wd.tm, Message.T0) catch unreachable;
        wd.addr = net.Address.resolveIp(wd.host, wd.port) catch unreachable;
        me.msgTo(me, M0_CONN, null);
    }

    fn connEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.io.getId(.{}) catch unreachable;
        wd.io.startConnect(&wd.addr) catch unreachable;
        wd.io.enableOut(&me.md.eq) catch unreachable;
    }

    fn connD1(me: *StageMachine, _: ?*StageMachine, _: ?*anyopaque) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        print("connected to '{s}:{}'\n", .{wd.host, wd.port});
        me.msgTo(me, M0_WORK, null);
    }

    fn connD2(me: *StageMachine, _: ?*StageMachine, _: ?*anyopaque) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        os.getsockoptError(wd.io.id) catch |err| {
            print("can not connect to '{s}:{}': {}\n", .{wd.host, wd.port, err});
        };
        me.msgTo(me, M1_WAIT, null);
    }

    // message from GUI machine
    fn workM0(me: *StageMachine, _: ?*StageMachine, dptr: ?*anyopaque) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        const cmd = @ptrToInt(dptr) - 1;
        wd.buf[wd.cnt] = @intCast(u8, cmd);
        wd.cnt += 1;
        wd.io.enableOut(&me.md.eq) catch unreachable;
    }

    fn workD1(me: *StageMachine, _: ?*StageMachine, dptr: ?*anyopaque) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        var io = util.opaqPtrTo(dptr, *EventSource);

        var i: usize = 0;
        while (wd.cnt > 0) {
            _ = os.write(io.id, wd.buf[i..i+1]) catch {
                me.msgTo(me, M1_WAIT, null);
                return;
            };
            i += 1;
            wd.cnt -= 1;
        }
    }

    fn workD2(me: *StageMachine, _: ?*StageMachine, _: ?*anyopaque) void {
        print("connection lost\n", .{});
        me.msgTo(me, M1_WAIT, null);
    }

    fn waitEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        os.close(wd.io.id);
        wd.tm.enable(&me.md.eq, .{2000}) catch unreachable;
    }

    // a key pressed but we are not connected
    fn waitM0(_: *StageMachine, _: ?*StageMachine, _: ?*anyopaque) void {
//        var wd = util.opaqPtrTo(me.data, *WorkerData);
        print("not connected\n", .{});
    }
};
