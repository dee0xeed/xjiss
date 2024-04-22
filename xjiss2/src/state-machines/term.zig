
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
const Signal = esrc.Signal;
const edsm = @import("../engine/edsm.zig");
const StageMachine = edsm.StageMachine;
const util = @import("../util.zig");

pub const Term = struct {

    const M0_WORK = Message.M0;
    const Data = struct {
        sg0: Signal,
        sg1: Signal,
    };

    sm: StageMachine,
    pd: Data,

    pub fn onHeap(a: Allocator, md: *MessageDispatcher) !*Term {

        var me = try a.create(Term);
        me.sm = try StageMachine.init(a, md, "TERMINATOR", 1, 2);
        me.sm.stages[0] = .{.sm = &me.sm, .name = "INIT", .enter = &initEnter};
        me.sm.stages[1] = .{.sm = &me.sm, .name = "WORK", .enter = &workEnter, .leave = &workLeave};

        var init = &me.sm.stages[0];
        var work = &me.sm.stages[1];

        init.setReflex(Message.M0, .{.jump_to = work});
        work.setReflex(Message.S0, .{.do_this = &workS0});
        work.setReflex(Message.S1, .{.do_this = &workS0});
        return me;
    }

    fn initEnter(sm: *StageMachine) void {
        //var me = @fieldParentPtr(Term, "sm", sm);
        var me: *Term = @fieldParentPtr("sm", sm);
        me.pd.sg0 = Signal.init(&me.sm, std.posix.SIG.INT, Message.S0) catch unreachable;
        me.pd.sg1 = Signal.init(&me.sm, std.posix.SIG.TERM, Message.S1) catch unreachable;
        sm.msgTo(sm, M0_WORK, null);
    }

    fn workEnter(sm: *StageMachine) void {
        //var me = @fieldParentPtr(Term, "sm", sm);
        var me: *Term = @fieldParentPtr("sm", sm);
        me.pd.sg0.es.enable() catch unreachable;
        me.pd.sg1.es.enable() catch unreachable;
    }

    fn workS0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        const es = util.opaqPtrTo(dptr, *EventSource);
        //var sg = @fieldParentPtr(Signal, "es", es);
        const sg: *Signal = @fieldParentPtr("es", es);
        print("got signal #{} from PID {}\n", .{sg.info.signo, sg.info.pid});
        sm.msgTo(null, Message.M0, null);
    }

    fn workLeave(sm: *StageMachine) void {
        _ = sm;
        // var me = @fieldParentPtr(Term, "sm", sm);
        print("Bye!\n", .{});
    }
};
