
const std = @import("std");
const os = std.os;
const mem = std.mem;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const mq = @import("../engine/message-queue.zig");
const MessageDispatcher = mq.MessageDispatcher;
const Message = mq.Message;

const esrc = @import("../engine//event-sources.zig");
const EventSource = esrc.EventSource;
const Timer = esrc.Timer;
const ClientSocket = esrc.ClientSocket;

const edsm = @import("../engine/edsm.zig");
const StageMachine = edsm.StageMachine;

const util = @import("../util.zig");

pub const Worker = struct {

    const M0_CONN = Message.M0;
    const M0_WORK = Message.M0;
    const M1_WAIT = Message.M1;

    const Data = struct {
        tm: Timer,
        sk: ClientSocket,
        host: []const u8,
        port: u16,
        buf: [16]u8,
        cnt: usize,
    };

    sm: StageMachine,
    wd: Data,

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, host: []const u8, port: u16) !*Worker {

        var me = try a.create(Worker);
        me.sm = try StageMachine.init(a, md, "WORKER", 1, 4);
        me.sm.stages[0] = .{.sm = &me.sm, .name = "INIT", .enter = &initEnter};
        me.sm.stages[1] = .{.sm = &me.sm, .name = "CONN", .enter = &connEnter};
        me.sm.stages[2] = .{.sm = &me.sm, .name = "WORK"};
        me.sm.stages[3] = .{.sm = &me.sm, .name = "WAIT", .enter = &waitEnter, .leave = &waitLeave};

        var init = &me.sm.stages[0];
        var conn = &me.sm.stages[1];
        var work = &me.sm.stages[2];
        var wait = &me.sm.stages[3];

        init.setReflex(Message.M0, .{.jump_to = conn});

        conn.setReflex(Message.D1, .{.do_this = &connD1});
        conn.setReflex(Message.D2, .{.do_this = &connD2});
        conn.setReflex(Message.M0, .{.jump_to = work});
        conn.setReflex(Message.M1, .{.jump_to = wait});

        work.setReflex(Message.M0, .{.do_this = &workM0});
        work.setReflex(Message.D1, .{.do_this = &workD1});
        work.setReflex(Message.D2, .{.do_this = &workD2});
        work.setReflex(Message.M1, .{.jump_to = wait});

        wait.setReflex(Message.T0, .{.jump_to = conn});
        wait.setReflex(Message.M0, .{.do_this = &waitM0});

        me.wd.host = host;
        me.wd.port = port;
        me.wd.cnt = 0;
        return me;
    }

    fn initEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(Worker, "sm", sm);
        me.wd.sk = ClientSocket.init(&me.sm, me.wd.host, me.wd.port) catch unreachable;
        me.wd.tm = Timer.init(&me.sm, Message.T0) catch unreachable;
        sm.msgTo(sm, M0_CONN, null);
    }

    fn connEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(Worker, "sm", sm);
        me.wd.sk.startConnect() catch unreachable;
        me.wd.sk.io.enableOut() catch unreachable;
    }

    fn connD1(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var me = @fieldParentPtr(Worker, "sm", sm);
        print("connected to '{s}:{}'\n", .{me.wd.host, me.wd.port});
        sm.msgTo(sm, M0_WORK, null);
    }

    fn connD2(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var me = @fieldParentPtr(Worker, "sm", sm);
        os.getsockoptError(me.wd.sk.io.es.id) catch |err| {
            print("can not connect to '{s}:{}': {}\n", .{me.wd.host, me.wd.port, err});
        };
        sm.msgTo(sm, M1_WAIT, null);
    }

    // message from GUI machine
    fn workM0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var me = @fieldParentPtr(Worker, "sm", sm);
        const cmd = @ptrToInt(dptr) - 1;
        me.wd.buf[me.wd.cnt] = @intCast(u8, cmd);
        me.wd.cnt += 1;
        me.wd.sk.io.enableOut() catch unreachable;
    }

    fn workD1(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var me = @fieldParentPtr(Worker, "sm", sm);
        var io = util.opaqPtrTo(dptr, *EventSource);

        var i: usize = 0;
        while (me.wd.cnt > 0) {
            _ = os.write(io.id, me.wd.buf[i..i+1]) catch {
                sm.msgTo(sm, M1_WAIT, null);
                return;
            };
            i += 1;
            me.wd.cnt -= 1;
        }
    }

    fn workD2(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        print("connection lost\n", .{});
        sm.msgTo(sm, M1_WAIT, null);
    }

    fn waitEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(Worker, "sm", sm);
        me.wd.tm.es.enable() catch unreachable;
        me.wd.tm.start(2000) catch unreachable;
    }

    fn waitLeave(sm: *StageMachine) void {
        var me = @fieldParentPtr(Worker, "sm", sm);
        // see https://github.com/ziglang/zig/issues/13677
        me.wd.sk.update() catch unreachable;
    }

    // a key pressed but we are not connected
    fn waitM0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = sm;
        _ = src;
        _ = dptr;
        print("not connected\n", .{});
    }
};
