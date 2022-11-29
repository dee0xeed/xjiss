
const std = @import("std");
const os = std.os;
const mem = std.mem;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const mq = @import("../engine/message-queue.zig");
const MessageDispatcher = mq.MessageDispatcher;
const MessageQueue = mq.MessageQueue;
const Message = mq.Message;
const esrc = @import("../engine//event-sources.zig");
const EventSource = esrc.EventSource;
const InOut = esrc.InOut;
const Client = esrc.ServerSocket.Client;
const edsm = @import("../engine/edsm.zig");
const StageMachine = edsm.StageMachine;

const MachinePool = @import("../machine-pool.zig").MachinePool;
const util = @import("../util.zig");

pub const Worker = struct {

    const M0_IDLE = Message.M0;
    const M0_RECV = Message.M0;
    const M0_GONE = Message.M0;
    const M1_TONE_ON = Message.M1;
    const M0_TONE_OFF = Message.M0;
    var number: u16 = 0;

    const Data = struct {
        pool: *MachinePool,
        listener: *StageMachine,
        client: *Client,
        sk: InOut,
        gui: *StageMachine,
        tone_number: u8,
    };

    sm: StageMachine,
    wd: Data,

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, pool: *MachinePool) !*Worker {

        number += 1;
        var me = try a.create(Worker);
        me.sm = try StageMachine.init(a, md, "SERVER", number, 3);
        me.sm.stages[0] = .{.sm = &me.sm, .name = "INIT", .enter = &initEnter};
        me.sm.stages[1] = .{.sm = &me.sm, .name = "IDLE", .enter = &idleEnter};
        me.sm.stages[2] = .{.sm = &me.sm, .name = "RECV", .enter = &recvEnter};

        var init = &me.sm.stages[0];
        var idle = &me.sm.stages[1];
        var recv = &me.sm.stages[2];

        init.setReflex(Message.M0, .{.jump_to = idle});
        idle.setReflex(Message.M1, .{.do_this = &idleM1});
        idle.setReflex(Message.M0, .{.jump_to = recv});
        recv.setReflex(Message.D0, .{.do_this = &recvD0});
        recv.setReflex(Message.D2, .{.do_this = &recvD2});
        recv.setReflex(Message.M0, .{.jump_to = idle});

        me.wd.pool = pool;
        return me;
    }

    pub fn setBuddy(me: *Worker, other: *StageMachine) void {
        me.wd.gui = other;
    }

    fn initEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(Worker, "sm", sm);
        me.wd.sk = InOut.init(&me.sm, -1);
        sm.msgTo(sm, M0_IDLE, null);
    }

    fn idleEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(Worker, "sm", sm);
        me.wd.listener = undefined;
        me.wd.client = undefined;
        me.wd.pool.put(&me.sm) catch unreachable;
    }

    fn idleM1(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        var me = @fieldParentPtr(Worker, "sm", sm);
        var client = util.opaqPtrTo(dptr, *Client);
        me.wd.listener = src.?;
        me.wd.client = client;
        sm.msgTo(sm, M0_RECV, null);
    }

    fn recvEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(Worker, "sm", sm);
        me.wd.sk.es.id = me.wd.client.fd;
        me.wd.sk.es.enable() catch unreachable;
    }

    fn recvD0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var me = @fieldParentPtr(Worker, "sm", sm);
        const ba = me.wd.sk.bytes_avail;
        if (0 == ba) {
            sm.msgTo(sm, M0_IDLE, null);
            sm.msgTo(me.wd.listener, M0_GONE, me.wd.client);
            return;
        }
        var cmd: [1]u8 = undefined;
        _ = os.read(me.wd.sk.es.id, cmd[0..]) catch {
            sm.msgTo(sm, M0_IDLE, null);
            sm.msgTo(me.wd.listener, M0_GONE, me.wd.client);
            return;
        };
        const byte = cmd[0];
        me.wd.tone_number = byte & 0x3F;
        const pressed: bool = ((byte & 0x80) == 0x80);
        if (pressed) {
            sm.msgTo(me.wd.gui, M1_TONE_ON, &me.wd.tone_number);
        } else {
            sm.msgTo(me.wd.gui, M0_TONE_OFF, &me.wd.tone_number);
        }
        me.wd.sk.es.enable() catch unreachable;
    }

    fn recvD2(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var me = @fieldParentPtr(Worker, "sm", sm);
        sm.msgTo(sm, M0_IDLE, null);
        sm.msgTo(me.wd.listener, M0_GONE, me.wd.client);
    }
};
