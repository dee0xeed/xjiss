
const std = @import("std");
const os = std.os;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const mq = @import("../engine/message-queue.zig");
const MessageDispatcher = mq.MessageDispatcher;
const MessageQueue = mq.MessageQueue;
const Message = mq.Message;
const esrc = @import("../engine//event-sources.zig");
const EventSource = esrc.EventSource;
const ServerSocket = esrc.ServerSocket;
const Signal = esrc.Signal;
const edsm = @import("../engine/edsm.zig");
const StageMachine = edsm.StageMachine;

const MachinePool = @import("../machine-pool.zig").MachinePool;
const Client = @import("Client.zig").Client;
const util = @import("../util.zig");

pub const Listener = struct {

    const M0_WORK = Message.M0;
    const M1_MEET = Message.M1;
    const M0_GONE = Message.M0;

    const Data = struct {
        sg0: Signal,
        sg1: Signal,
        lsk: ServerSocket,
        port: u16,
        wpool: *MachinePool,
    };

    sm: StageMachine,
    pd: Data,

    pub fn onHeap(
        a: Allocator,
        md: *MessageDispatcher,
        port: u16,
        wpool: *MachinePool
    ) !*Listener {

        var me = try a.create(Listener);
        me.sm = try StageMachine.init(a, md, "LISTENER", 1, 2);
        me.sm.stages[0] = .{.sm = &me.sm, .name = "INIT", .enter = &initEnter};
        me.sm.stages[1] = .{.sm = &me.sm, .name = "WORK", .enter = &workEnter, .leave = &workLeave};

        var init = &me.sm.stages[0];
        var work = &me.sm.stages[1];

        init.setReflex(Message.M0, .{.transition = work});
        work.setReflex(Message.D0, .{.action = &workD0});
        work.setReflex(Message.M0, .{.action = &workM0});
        work.setReflex(Message.S0, .{.action = &workS0});
        work.setReflex(Message.S1, .{.action = &workS0});

        me.pd.port = port;
        me.pd.wpool = wpool;
        return me;
    }

    fn initEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(Listener, "sm", sm);
        me.pd.sg0 = Signal.init(&me.sm, os.SIG.INT, Message.S0) catch unreachable;
        me.pd.sg1 = Signal.init(&me.sm, os.SIG.TERM, Message.S1) catch unreachable;
        me.pd.lsk = ServerSocket.init(&me.sm, me.pd.port) catch unreachable;
        sm.msgTo(sm, M0_WORK, null);
    }

    fn workEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(Listener, "sm", sm);
        me.pd.lsk.io.es.enable() catch unreachable;
        me.pd.sg0.es.enable() catch unreachable;
        me.pd.sg1.es.enable() catch unreachable;
    }

    // incoming connection
    fn workD0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var me = @fieldParentPtr(Listener, "sm", sm);
        me.pd.lsk.io.es.enable() catch unreachable;
        var fd = me.pd.lsk.acceptClient() catch unreachable;
        var ptr = sm.allocator.create(Client) catch unreachable;
        var client = @ptrCast(*Client, @alignCast(@alignOf(*Client), ptr));
        client.fd = fd;

        var wsm = me.pd.wpool.get();
        if (wsm) |worker| {
            sm.msgTo(worker, M1_MEET, client);
        } else {
            sm.msgTo(sm, M0_GONE, client);
        }
    }

    // message from worker machine (client gone)
    // or from self (if no workers were available)
    fn workM0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var client = util.opaqPtrTo(dptr, *Client);
        os.close(client.fd);
        sm.allocator.destroy(client);
    }

    fn workS0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var es = util.opaqPtrTo(dptr, *EventSource);
        var sg = @fieldParentPtr(Signal, "es", es);
        print("got signal #{} from PID {}\n", .{sg.info.signo, sg.info.pid});
        sm.msgTo(null, Message.M0, null);
    }

    fn workLeave(sm: *StageMachine) void {
        var me = @fieldParentPtr(Listener, "sm", sm);
        me.pd.lsk.io.es.disable() catch unreachable;
        print("Bye!\n", .{});
    }
};
