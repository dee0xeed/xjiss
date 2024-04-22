
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
const util = @import("../util.zig");

pub const Listener = struct {

    const M0_WORK = Message.M0;
    const M1_MEET = Message.M1;
    const M0_GONE = Message.M0;

    const Data = struct {
        lsk: ServerSocket,
        port: u16,
        backlog: u31,
        wpool: *MachinePool,
    };

    sm: StageMachine,
    pd: Data,

    pub fn onHeap(
        a: Allocator,
        md: *MessageDispatcher,
        port: u16,
        backlog: u31,
        wpool: *MachinePool
    ) !*Listener {

        var me = try a.create(Listener);
        me.sm = try StageMachine.init(a, md, "LISTENER", 1, 2);
        me.sm.stages[0] = .{.sm = &me.sm, .name = "INIT", .enter = &initEnter};
        me.sm.stages[1] = .{.sm = &me.sm, .name = "WORK", .enter = &workEnter};

        var init = &me.sm.stages[0];
        var work = &me.sm.stages[1];

        init.setReflex(Message.M0, .{.jump_to = work});
        work.setReflex(Message.D2, .{.do_this = &workD2});
        work.setReflex(Message.D3, .{.do_this = &workD3});
        work.setReflex(Message.M0, .{.do_this = &workM0});

        me.pd.port = port;
        me.pd.backlog = backlog;
        me.pd.wpool = wpool;
        return me;
    }

    fn initEnter(sm: *StageMachine) void {
        //var me = @fieldParentPtr(Listener, "sm", sm);
        var me: *Listener = @fieldParentPtr("sm", sm);
        me.pd.lsk = ServerSocket.init(&me.sm, me.pd.port, me.pd.backlog) catch unreachable;
        sm.msgTo(sm, M0_WORK, null);
    }

    fn workEnter(sm: *StageMachine) void {
        //var me = @fieldParentPtr(Listener, "sm", sm);
        var me: *Listener = @fieldParentPtr("sm", sm);
        me.pd.lsk.es.enable() catch unreachable;
    }

    // Q: is this ever possible?
    fn workD2(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        //var me = @fieldParentPtr(Listener, "sm", sm);
        const me: *Listener = @fieldParentPtr("sm", sm);
        _ = src;
        _ = dptr;
        print("OOPS, error on listening socket (fd={}) happened\n", .{me.pd.lsk.es.id});
        std.posix.raise(std.posix.SIG.TERM) catch unreachable;
    }

    // incoming connection
    fn workD3(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        //var me = @fieldParentPtr(Listener, "sm", sm);
        var me: *Listener = @fieldParentPtr("sm", sm);
        me.pd.lsk.es.enable() catch unreachable;
        const peer = sm.allocator.create(ServerSocket.Client) catch unreachable;
        peer.* = me.pd.lsk.acceptClient() orelse {
            sm.allocator.destroy(peer);
            return;
        };
        print("client from {}\n", .{peer.addr});
        const wsm = me.pd.wpool.get();
        if (wsm) |worker| {
            sm.msgTo(worker, M1_MEET, peer);
        } else {
            sm.msgTo(sm, M0_GONE, peer);
        }
    }

    // message from worker machine (client gone)
    // or from self (if no workers were available)
    fn workM0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        const peer = util.opaqPtrTo(dptr, *ServerSocket.Client);
        std.posix.close(peer.fd);
        print("client from {} gone\n", .{peer.addr});
        sm.allocator.destroy(peer);
    }
};
