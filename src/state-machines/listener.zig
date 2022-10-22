
const std = @import("std");
const os = std.os;
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

const MachinePool = @import("../machine-pool.zig").MachinePool;
const Client = @import("Client.zig").Client;
const util = @import("../util.zig");

pub const Listener = struct {

    const M0_WORK = Message.M0;
    const M1_MEET = Message.M1;
    const M0_GONE = Message.M0;

    const ListenerData = struct {
        sg0: EventSource,
        sg1: EventSource,
        io0: EventSource, // listening socket
        port: u16,
        wpool: *MachinePool,
    };

    pub fn onHeap(
        a: Allocator,
        md: *MessageDispatcher,
        port: u16,
        wpool: *MachinePool
    ) !*StageMachine {

        var me = try StageMachine.onHeap(a, md, "LISTENER", 1);
        try me.addStage(.{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(.{.name = "WORK", .enter = &workEnter, .leave = &workLeave});

        var init = &me.stages.items[0];
        var work = &me.stages.items[1];

        init.setReflex(.sm, Message.M0, .{.transition = work});
        work.setReflex(.io, Message.D0, .{.action = &workD0});
        work.setReflex(.sm, Message.M0, .{.action = &workM0});
        work.setReflex(.sg, Message.S0, .{.action = &workS0});
        work.setReflex(.sg, Message.S1, .{.action = &workS0});

        me.data = me.allocator.create(ListenerData) catch unreachable;
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        pd.port = port;
        pd.wpool = wpool;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        me.initSignal(&pd.sg0, os.SIG.INT, Message.S0) catch unreachable;
        me.initSignal(&pd.sg1, os.SIG.TERM, Message.S1) catch unreachable;
        me.initListener(&pd.io0, pd.port) catch unreachable;
        me.msgTo(me, M0_WORK, null);
    }

    fn workEnter(me: *StageMachine) void {
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        pd.io0.enable(&me.md.eq, .{}) catch unreachable;
        pd.sg0.enable(&me.md.eq, .{}) catch unreachable;
        pd.sg1.enable(&me.md.eq, .{}) catch unreachable;
    }

    // incoming connection
    fn workD0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        var io = util.opaqPtrTo(dptr, *EventSource);
        io.enable(&me.md.eq, .{}) catch unreachable;
        const fd = io.acceptClient() catch unreachable;
        var ptr = me.allocator.create(Client) catch unreachable;
        var client = @ptrCast(*Client, @alignCast(@alignOf(*Client), ptr));
        client.fd = fd;

        var sm = pd.wpool.get();
        if (sm) |worker| {
            me.msgTo(worker, M1_MEET, client);
        } else {
            me.msgTo(me, M0_GONE, client);
        }
    }

    // message from worker machine (client gone)
    // or from self (if no workers were available)
    fn workM0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var client = util.opaqPtrTo(dptr, *Client);
        os.close(client.fd);
        me.allocator.destroy(client);
    }

    fn workS0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var sg = util.opaqPtrTo(dptr, *EventSource);
        var si = sg.info.sg.sig_info;
        print("got signal #{} from PID {}\n", .{si.signo, si.pid});
        me.msgTo(null, Message.M0, null);
    }

    fn workLeave(me: *StageMachine) void {
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        pd.io0.disable(&me.md.eq) catch unreachable;
        print("Bye!\n", .{});
    }
};
