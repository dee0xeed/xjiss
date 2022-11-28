
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

    const ListenerData = struct {
        sg0: Signal,
        sg1: Signal,
        lsk: ServerSocket,
        port: u16,
        wpool: *MachinePool,
    };

    pub fn onHeap(
        a: Allocator,
        md: *MessageDispatcher,
        port: u16,
        wpool: *MachinePool
    ) !*StageMachine {

        var me = try StageMachine.onHeap(a, md, "LISTENER", 1, 2);
        me.stages[0] = .{.name = "INIT", .enter = &initEnter, .leave = null};
        me.stages[1] = .{.name = "WORK", .enter = &workEnter, .leave = &workLeave};

        var init = &me.stages[0];
        var work = &me.stages[1];

        init.setReflex(Message.M0, .{.transition = work});
        work.setReflex(Message.D0, .{.action = &workD0});
        work.setReflex(Message.M0, .{.action = &workM0});
        work.setReflex(Message.S0, .{.action = &workS0});
        work.setReflex(Message.S1, .{.action = &workS0});

        me.data = me.allocator.create(ListenerData) catch unreachable;
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        pd.port = port;
        pd.wpool = wpool;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        pd.sg0 = Signal.init(me, os.SIG.INT, Message.S0) catch unreachable;
        pd.sg1 = Signal.init(me, os.SIG.TERM, Message.S1) catch unreachable;
        pd.lsk = ServerSocket.init(me, pd.port) catch unreachable;
        me.msgTo(me, M0_WORK, null);
    }

    fn workEnter(me: *StageMachine) void {
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        pd.lsk.io.es.enable() catch unreachable;
        pd.sg0.es.enable() catch unreachable;
        pd.sg1.es.enable() catch unreachable;
    }

    // incoming connection
    fn workD0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        pd.lsk.io.es.enable() catch unreachable;
        var fd = pd.lsk.acceptClient() catch unreachable;
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
        var es = util.opaqPtrTo(dptr, *EventSource);
        var sg = @fieldParentPtr(Signal, "es", es);
        print("got signal #{} from PID {}\n", .{sg.info.signo, sg.info.pid});
        me.msgTo(null, Message.M0, null);
    }

    fn workLeave(me: *StageMachine) void {
        var pd = util.opaqPtrTo(me.data, *ListenerData);
        pd.lsk.io.es.disable() catch unreachable;
        print("Bye!\n", .{});
    }
};
