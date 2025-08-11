
const std = @import("std");
const os = std.os;
const mem = std.mem;
const net = std.net;
const print = std.debug.print;

const timerFd = std.posix.timerfd_create;
const timerFdSetTime = os.linux.timerfd_settime;
const TimeSpec = os.linux.timespec;
const ITimerSpec = os.linux.itimerspec;

const signalFd = std.posix.signalfd;
const SigSet = std.posix.sigset_t;
const SIG = std.posix.SIG;
const SigInfo = os.linux.signalfd_siginfo;

const fsysFd = os.inotify_init1;
const FsysEvent = os.linux.inotify_event;
const fsysAddWatch = os.inotify_add_watch;

const edsm = @import("edsm.zig");
const StageMachine = edsm.StageMachine;
const ecap = @import("event-capture.zig");
const Message = @import("message-queue.zig").Message;

pub const EventSource = struct {

    id: i32 = -1, // fd in most cases, but not always
    owner: *StageMachine,
    eq: *ecap.EventQueue,
    // "virtual method"
    getMessageCodeImpl: *const fn(es: *EventSource, event_mask: u32) anyerror!u8,

    pub fn getMessageCode(es: *EventSource, event_mask: u32) !u8 {
        return try es.getMessageCodeImpl(es, event_mask);
    }

    // "final methods"
    pub fn enable(es: *EventSource) !void {
        try es.eq.enableCanRead(es);
    }
    pub fn disable(es: *EventSource) !void {
        try es.eq.disableEventSource(es);
    }
};

pub const Signal = struct {
    es: EventSource,
    code: u8,
    info: SigInfo = undefined,

    fn getId(signo: u6) !i32 {
        var sset: SigSet = std.posix.empty_sigset;
        os.linux.sigaddset(&sset, signo);
        _ = os.linux.sigprocmask(SIG.BLOCK, &sset, null);
        return signalFd(-1, &sset, 0);
    }

    pub fn init(sm: *StageMachine, signo: u6, code: u8) !Signal {
        return Signal {
            .es = .{
                .id = try getId(signo),
                .owner = sm,
                .getMessageCodeImpl = &readInfo,
                .eq = sm.md.eq,
            },
            .code = code,
        };
    }

    fn readInfo(es: *EventSource, event_mask: u32) !u8 {
        // check event mask here...
        _ = event_mask;
        var self: *Signal = @fieldParentPtr("es", es);
        const p1 = &self.info;
        var p2: [*]u8 = @ptrCast(@alignCast(p1));
        _ = try std.posix.read(es.id, p2[0..@sizeOf(SigInfo)]);
        return self.code;
    }
};

pub const Timer = struct {
    es: EventSource,
    code: u8,
    nexp: u64 = 0,

    pub fn init(sm: *StageMachine, code: u8) !Timer {
        return Timer {
            .es = .{
                .id = try timerFd(std.os.linux.TIMERFD_CLOCK.REALTIME, .{}),
                .owner = sm,
                .getMessageCodeImpl = &readInfo,
                .eq = sm.md.eq,
            },
            .code = code,
        };
    }

    fn setValue(fd: i32, msec: u32) !void {
        const its = ITimerSpec {
            .it_interval = TimeSpec {
                .sec = 0,
                .nsec = 0,
            },
            .it_value = TimeSpec {
                .sec = msec / 1000,
                .nsec = (msec % 1000) * 1000 * 1000,
            },
        };
        const tid: os.linux.TFD.TIMER = .{};
        _ = timerFdSetTime(fd, tid, &its, null);
    }

    pub fn start(tm: *Timer, msec: u32) !void {
        return try setValue(tm.es.id, msec);
    }

    pub fn stop(tm: *Timer) !void {
        return try setValue(tm.es.id, 0);
    }

    pub fn readInfo(es: *EventSource, event_mask: u32) !u8 {
        _ = event_mask;
        var self: *Timer = @fieldParentPtr("es", es);
        const p1 = &self.nexp;
        var p2: [*]u8 = @ptrCast(@alignCast(p1));
        var buf = p2[0..@sizeOf(u64)];
        _ = try std.posix.read(es.id, buf[0..]);
        return self.code;
    }
};

pub const ServerSocket = struct {

    es: EventSource,
    port: u16,

    pub const Client = struct {
        fd: i32,
        addr: net.Address,
    };

    fn getId(port: u16, backlog: u31) !i32 {
        const fd = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        errdefer std.posix.close(fd);
        const yes = mem.toBytes(@as(c_int, 1));
        try std.posix.setsockopt(fd, std.posix.SOL.SOCKET, std.posix.SO.REUSEADDR, &yes);
        const addr = net.Address.initIp4(.{0,0,0,0}, port);
        const socklen = addr.getOsSockLen();
        try std.posix.bind(fd, &addr.any, socklen);
        try std.posix.listen(fd, backlog);
        return fd;
    }

    pub fn init(sm: *StageMachine, port: u16, backlog: u31) !ServerSocket {
        return ServerSocket {
            .es = .{
                .id = try getId(port, backlog),
                .owner = sm,
                .getMessageCodeImpl = &getMessageCode,
                .eq = sm.md.eq,
            },
            .port = port,
       };
    }

    fn getMessageCode(es: *EventSource, events: u32) !u8 {
        const EPOLL = os.linux.EPOLL;
        _ = es;
        if (0 != events & (EPOLL.ERR | EPOLL.HUP | EPOLL.RDHUP))
            // Q: is this ever possible?
            return Message.D2;
        return Message.D3;
    }

    pub fn acceptClient(self: *ServerSocket) ?Client {
        var addr: net.Address = undefined;
        var alen: std.posix.socklen_t = @sizeOf(net.Address);
        const fd  = std.posix.accept(self.es.id, &addr.any, &alen, 0) catch |err| {
            print("OOPS, accept() failed: {}\n", .{err});
            return null;
        };
        return .{.fd = fd, .addr = addr};
    }
};

pub const FileSystem = struct {
    es: EventSource,
    buf: [1024]u8 = undefined,
    event: *FsysEvent = undefined, // points to .buf[0]
    fname: []u8 = undefined, // points to .buf[@sizeOf(FsysEvent)]

    pub fn init(sm: *StageMachine) !FileSystem {
        return FileSystem {
            .es = .{
                .id = try fsysFd(0),
                .owner = sm,
                .getMessageCodeImpl = &readInfo,
                .eq = sm.md.eq,
            },
        };
    }

    pub fn setupPointers(fs: *FileSystem) void {
        fs.event = @ptrCast(@alignCast(&fs.buf[0]));
        fs.fname = fs.buf[@sizeOf(FsysEvent)..];
    }

    // a little bit tricky function that reads
    // exactly *one* event from inotify system
    // regardless of whether it has file name or not
    fn readInfo(es: *EventSource, event_mask: u32) !u8 {
        _ = event_mask;
        var self: *FileSystem = @fieldParentPtr("es", es);
        mem.set(u8, self.buf[0..], 0);
        var len: usize = @sizeOf(FsysEvent);
        while (true) {
            const ret = os.system.read(es.id, &self.buf, len);
            if (os.system.getErrno(ret) == .SUCCESS) break;
            if (os.system.getErrno(ret) != .INVAL) unreachable;
            // EINVAL => buffer too small
            // increase len and try again
            len += @sizeOf(FsysEvent);
            // check len here
        }
        print("file system events = {b:0>32}\n", .{self.event.mask});
        const ctz: u8 = @ctz(self.event.mask);
        return Message.FROW | ctz;
    }

    pub fn addWatch(self: *FileSystem, path: []const u8, mask: u32) !void {
        const wd = try fsysAddWatch(self.es.id, path, mask);
        _ = wd;
    }
};

pub const InOut = struct {
    es: EventSource,
    bytes_avail: usize = undefined,

    pub fn init(sm: *StageMachine, fd: i32) InOut {
        return InOut {
            .es = .{
                .id = fd,
                .owner = sm,
                .getMessageCodeImpl = &getMessageCode,
                .eq = sm.md.eq,
            },
        };
    }

    fn getMessageCode(es: *EventSource, events: u32) !u8 {

        const EPOLL = os.linux.EPOLL;
        const FIONREAD = os.linux.T.FIONREAD;
        var self: *InOut = @fieldParentPtr("es", es);

        if (0 != events & (EPOLL.ERR | EPOLL.HUP | EPOLL.RDHUP)) {
            return Message.D2;
        }

        if (0 != events & EPOLL.OUT) {
            return Message.D1;
        }

        if (0 != events & EPOLL.IN) {
            var ba: u32 = 0;
            _ = std.os.linux.ioctl(es.id, FIONREAD, @intFromPtr(&ba)); // IOCINQ
            // see https://github.com/ziglang/zig/issues/12961
            self.bytes_avail = ba;
            return Message.D0;
        }

        unreachable;
    }

    pub fn enableOut(self: *InOut) !void {
        try self.es.eq.enableCanWrite(&self.es);
    }
};

pub const ClientSocket = struct {

    io: InOut,
    host: []const u8,
    port: u16,
    addr: net.Address,

    pub fn init(sm: *StageMachine, host: []const u8, port: u16) !ClientSocket {
        const id = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        return ClientSocket {
            .io = InOut.init(sm, id),
            .host = host,
            .port = port,
            .addr = net.Address.resolveIp(host, port) catch unreachable,
        };
    }

    pub fn startConnect(self: *ClientSocket) !void {

        const InProgress = std.posix.ConnectError.WouldBlock;

        var flags = std.posix.fcntl(self.io.es.id, std.posix.F.GETFL, 0) catch unreachable;
        flags |= std.posix.SOCK.NONBLOCK;
        _ = std.posix.fcntl(self.io.es.id, std.posix.F.SETFL, flags) catch unreachable;

        std.posix.connect(self.io.es.id, &self.addr.any, self.addr.getOsSockLen()) catch |err| {
            switch (err) {
                InProgress => return,
                else => return err,
            }
        };
    }

    pub fn update(self: *ClientSocket) !void {
        if (self.io.es.id != -1) {
            std.posix.close(self.io.es.id);
            self.io.es.id = try std.posix.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP);
        } else unreachable;
    }
};
