
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

    const WorkerData = struct {
        tm: Timer,
        sk: ClientSocket,
        host: []const u8,
        port: u16,
        buf: [16]u8,
        cnt: usize,
    };

    pub fn onHeap (
        a: Allocator,
        md: *MessageDispatcher,
        host: []const u8,
        port: u16,
    ) !*StageMachine {

        var me = try StageMachine.onHeap(a, md, "WORKER", 1, 4);
        me.stages[0] = .{.name = "INIT", .enter = &initEnter};
        me.stages[1] = .{.name = "CONN", .enter = &connEnter};
        me.stages[2] = .{.name = "WORK"};
        me.stages[3] = .{.name = "WAIT", .enter = &waitEnter, .leave = &waitLeave};

        var init = &me.stages[0];
        var conn = &me.stages[1];
        var work = &me.stages[2];
        var wait = &me.stages[3];

        init.setReflex(Message.M0, .{.transition = conn});

        conn.setReflex(Message.D1, .{.action = &connD1});
        conn.setReflex(Message.D2, .{.action = &connD2});
        conn.setReflex(Message.M0, .{.transition = work});
        conn.setReflex(Message.M1, .{.transition = wait});

        work.setReflex(Message.M0, .{.action = &workM0});
        work.setReflex(Message.D1, .{.action = &workD1});
        work.setReflex(Message.D2, .{.action = &workD2});
        work.setReflex(Message.M1, .{.transition = wait});

        wait.setReflex(Message.T0, .{.transition = conn});
        wait.setReflex(Message.M0, .{.action = &waitM0});

        me.data = me.allocator.create(WorkerData) catch unreachable;
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.host = host;
        wd.port = port;
        wd.cnt = 0;
        return me;
    }

    fn initEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.sk = ClientSocket.init(me, wd.host, wd.port) catch unreachable;
        wd.tm = Timer.init(me, Message.T0) catch unreachable;
        me.msgTo(me, M0_CONN, null);
    }

    fn connEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.sk.startConnect() catch unreachable;
        wd.sk.io.enableOut() catch unreachable;
    }

    fn connD1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        print("connected to '{s}:{}'\n", .{wd.host, wd.port});
        me.msgTo(me, M0_WORK, null);
    }

    fn connD2(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        os.getsockoptError(wd.sk.io.es.id) catch |err| {
            print("can not connect to '{s}:{}': {}\n", .{wd.host, wd.port, err});
        };
        me.msgTo(me, M1_WAIT, null);
    }

    // message from GUI machine
    fn workM0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        const cmd = @ptrToInt(dptr) - 1;
        wd.buf[wd.cnt] = @intCast(u8, cmd);
        wd.cnt += 1;
        wd.sk.io.enableOut() catch unreachable;
    }

    fn workD1(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
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

    fn workD2(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        print("connection lost\n", .{});
        me.msgTo(me, M1_WAIT, null);
    }

    fn waitEnter(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        wd.tm.es.enable() catch unreachable;
        wd.tm.start(2000) catch unreachable;
    }

    fn waitLeave(me: *StageMachine) void {
        var wd = util.opaqPtrTo(me.data, *WorkerData);
        // see https://github.com/ziglang/zig/issues/13677
        wd.sk.update() catch unreachable;
    }

    // a key pressed but we are not connected
    fn waitM0(me: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = me;
        _ = src;
        _ = dptr;
//        var wd = util.opaqPtrTo(me.data, *WorkerData);
        print("not connected\n", .{});
    }
};
