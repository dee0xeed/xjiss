
const std = @import("std");
const os = std.os;
const mem = std.mem;
const math = std.math;
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
const Client = @import("Client.zig").Client;
//const Context =  @import("../common-sm/context.zig").IoContext;
const util = @import("../util.zig");

pub const Worker = struct {

    const M0_IDLE = Message.M0;
    const M0_RECV = Message.M0;
    const M0_GONE = Message.M0;
//    const M2_FAIL = Message.M2;
    const M1_TONE_ON = Message.M1;
    const M0_TONE_OFF = Message.M0;
    var number: u16 = 0;

    const WorkerData = struct {
        pool: *MachinePool,
        listener: *StageMachine,
        client: *Client,
        io: EventSource,
        gui: *StageMachine,
        tone_number: u8,
    };

    pub fn onHeap (a: Allocator, md: *MessageDispatcher, pool: *MachinePool) !*StageMachine {

        number += 1;
        var me = try StageMachine.onHeap(a, md, "SERVER", number);
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "IDLE", .enter = &idleEnter, .leave = null});
        try me.addStage(Stage{.name = "RECV", .enter = &recvEnter, .leave = null});

        var init = &me.stages.items[0];
        var idle = &me.stages.items[1];
        var recv = &me.stages.items[2];

        init.setReflex(.sm, Message.M0, Reflex{.transition = idle});
        idle.setReflex(.sm, Message.M1, Reflex{.action = &idleM1});
        idle.setReflex(.sm, Message.M0, Reflex{.transition = recv});
        recv.setReflex(.io, Message.D0, Reflex{.action = &recvD0});
        recv.setReflex(.io, Message.D2, Reflex{.action = &recvD2});
        recv.setReflex(.sm, Message.M0, Reflex{.transition = idle});

        me.data = me.allocator.create(WorkerData) catch unreachable;
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.pool = pool;
        return me;
    }

    pub fn setBuddy(self: *StageMachine, other: *StageMachine) void {
        var wd = util.opaqPtrTo(self.data, *WorkerData);
        wd.gui = other;
    }

    fn initEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        me.initIo(&wd.io);
        me.msgTo(me, M0_IDLE, null);
    }

    fn idleEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.listener = undefined;
        wd.client = undefined;
        wd.pool.put(me) catch unreachable;
    }

    fn idleM1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        var client = util.opaqPtrTo(dptr, *Client);
        wd.listener = src.?;
        wd.client = client;
        me.msgTo(me, M0_RECV, null);
    }

    fn recvEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.io.id = wd.client.fd;
        wd.io.enable(&me.md.eq, .{}) catch unreachable;
    }

    fn recvD0(me: *StageMachine, _: ?*StageMachine, dptr: ?*anyopaque) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        var io = util.opaqPtrTo(dptr, *EventSource);
        const ba = io.info.io.bytes_avail;
        if (0 == ba) {
            me.msgTo(me, M0_IDLE, null);
            me.msgTo(wd.listener, M0_GONE, wd.client);
            return;
        }
        var cmd: [1]u8 = undefined;
        _ = os.read(io.id, cmd[0..]) catch {
            me.msgTo(me, M0_IDLE, null);
            me.msgTo(wd.listener, M0_GONE, wd.client);
            return;
        };
        const byte = cmd[0];
        wd.tone_number = byte & 0x3F;
        const pressed: bool = ((byte & 0x80) == 0x80);
        print("tn = {}, pressed = {}\n", .{wd.tone_number, pressed});
        if (pressed) {
            me.msgTo(wd.gui, M1_TONE_ON, &wd.tone_number);
        } else {
            me.msgTo(wd.gui, M0_TONE_OFF, &wd.tone_number);
        }
        io.enable(&me.md.eq, .{}) catch unreachable;
    }

    fn recvD2(me: *StageMachine, _: ?*StageMachine, _: ?*anyopaque) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        me.msgTo(me, M0_IDLE, null);
        me.msgTo(wd.listener, M0_GONE, wd.client);
    }
};
