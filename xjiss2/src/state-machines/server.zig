
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
const edsm = @import("../engine/edsm.zig");
const StageMachine = edsm.StageMachine;

const MachinePool = @import("../machine-pool.zig").MachinePool;
const Client = @import("Client.zig").Client;
const util = @import("../util.zig");

pub const Worker = struct {

    const M0_IDLE = Message.M0;
    const M0_RECV = Message.M0;
    const M0_GONE = Message.M0;
    const M1_TONE_ON = Message.M1;
    const M0_TONE_OFF = Message.M0;
    var number: u16 = 0;

    const WorkerData = struct {
        pool: *MachinePool,
        listener: *StageMachine,
        client: *Client,
        sk: InOut,
        gui: *StageMachine,
        tone_number: u8,
    };

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, pool: *MachinePool) !*StageMachine {

        number += 1;
        var me = try StageMachine.onHeap(a, md, "SERVER", number, 3);
        me.stages[0] = .{.name = "INIT", .enter = &initEnter};
        me.stages[1] = .{.name = "IDLE", .enter = &idleEnter};
        me.stages[2] = .{.name = "RECV", .enter = &recvEnter};

        var init = &me.stages[0];
        var idle = &me.stages[1];
        var recv = &me.stages[2];

        init.setReflex(Message.M0, .{.transition = idle});
        idle.setReflex(Message.M1, .{.action = &idleM1});
        idle.setReflex(Message.M0, .{.transition = recv});
        recv.setReflex(Message.D0, .{.action = &recvD0});
        recv.setReflex(Message.D2, .{.action = &recvD2});
        recv.setReflex(Message.M0, .{.transition = idle});

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
        wd.sk = InOut.init(me, -1);
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
        wd.sk.es.id = wd.client.fd;
        wd.sk.es.enable() catch unreachable;
    }

    fn recvD0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        const ba = wd.sk.bytes_avail;
        if (0 == ba) {
            me.msgTo(me, M0_IDLE, null);
            me.msgTo(wd.listener, M0_GONE, wd.client);
            return;
        }
        var cmd: [1]u8 = undefined;
        _ = os.read(wd.sk.es.id, cmd[0..]) catch {
            me.msgTo(me, M0_IDLE, null);
            me.msgTo(wd.listener, M0_GONE, wd.client);
            return;
        };
        const byte = cmd[0];
        wd.tone_number = byte & 0x3F;
        const pressed: bool = ((byte & 0x80) == 0x80);
        if (pressed) {
            me.msgTo(wd.gui, M1_TONE_ON, &wd.tone_number);
        } else {
            me.msgTo(wd.gui, M0_TONE_OFF, &wd.tone_number);
        }
        wd.sk.es.enable() catch unreachable;
    }

    fn recvD2(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        me.msgTo(me, M0_IDLE, null);
        me.msgTo(wd.listener, M0_GONE, wd.client);
    }
};
