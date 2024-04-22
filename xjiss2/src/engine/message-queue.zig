
const std = @import("std");
const edsm = @import("edsm.zig");
const ecap = @import("event-capture.zig");

/// Generic (non-growable) ring buffer
pub fn RingBuffer(comptime T: type, comptime capacity: u16) type {

    return struct {
        const Self = @This();
        cap: u16 = capacity,
        storage: [capacity]T = undefined,
        index_mask: u16 = capacity - 1,
        r_index: u16 = 0,
        w_index: u16 = capacity - 1,
        n_items: u16 = 0,

        const Error = error {
            IsFull,
        };

        pub fn put(self: *Self, item: T) !void {
            if (self.n_items == self.cap) return Error.IsFull;
            self.w_index += 1;
            self.w_index &= self.index_mask;
            self.storage[self.w_index] = item;
            self.n_items += 1;
        }

        pub fn get(self: *Self) ?T {
            if (0 == self.n_items) return null;
            const item = self.storage[self.r_index];
            self.n_items -= 1;
            self.r_index += 1;
            self.r_index &= self.index_mask;
            return item;
        }
    };
}

/// This structure decribes a message being sent to stage machines
pub const Message = struct {

    /// internal messages
    pub const M0: u4 = 0;
    pub const M1: u4 = 1;
    pub const M2: u4 = 2;
    pub const M3: u4 = 3;
    pub const M4: u4 = 4;
    pub const M5: u4 = 5;
    pub const M6: u4 = 6;
    pub const M7: u4 = 7;

    pub const DROW: u8 = (1 << 4);
    /// read() will not block (POLLIN)
    pub const D0: u8 = DROW | 0;
    /// write() will not block/connection established (POLLOUT)
    pub const D1: u8 = DROW | 1;
    /// error happened (POLLERR, POLLHUP, POLLRDHUP)
    pub const D2: u8 = DROW | 2;
    /// accept() will not block (POLLIN)
    pub const D3: u8 = DROW | 3;

    /// signals
    const SROW: u8 = (2 << 4);
    pub const S0: u8 = SROW | 0;
    pub const S1: u8 = SROW | 1;
    pub const S2: u8 = SROW | 2;

    /// timers
    const TROW: u8 = (3 << 4);
    pub const T0: u8 = TROW | 0;
    pub const T1: u8 = TROW | 1;
    pub const T2: u8 = TROW | 2;

    /// file system events
    pub const FROW: u8 = (4 << 4);
    pub const F00: u8 = FROW |  0; // IN_ACCESS 0x00000001 /* File was accessed */
    pub const F01: u8 = FROW |  1; // IN_MODIFY 0x00000002 /* File was modified */
    pub const F02: u8 = FROW |  2; // IN_ATTRIB 0x00000004 /* Metadata changed */
    pub const F03: u8 = FROW |  3; // IN_CLOSE_WRITE 0x00000008 /* Writtable file was closed */
    pub const F04: u8 = FROW |  4; // IN_CLOSE_NOWRITE 0x00000010 /* Unwrittable file closed */
    pub const F05: u8 = FROW |  5; // IN_OPEN 0x00000020 /* File was opened */
    pub const F06: u8 = FROW |  6; // IN_MOVED_FROM 0x00000040 /* File was moved from X */
    pub const F07: u8 = FROW |  7; // IN_MOVED_TO 0x00000080 /* File was moved to Y */
    pub const F08: u8 = FROW |  8; // IN_CREATE 0x00000100 /* Subfile was created */
    pub const F09: u8 = FROW |  9; // IN_DELETE 0x00000200 /* Subfile was deleted */
    pub const F10: u8 = FROW | 10; // IN_DELETE_SELF 0x00000400 /* Self was deleted */
    pub const F11: u8 = FROW | 11; // IN_MOVE_SELF 0x00000800 /* Self was moved */
    pub const F12: u8 = FROW | 12; // this bit is unused
    pub const F13: u8 = FROW | 13; // IN_UNMOUNT 0x00002000 /* Backing fs was unmounted */
    pub const F14: u8 = FROW | 14; // IN_Q_OVERFLOW 0x00004000 /* Event queue overflowed */
    pub const F15: u8 = FROW | 15; // IN_IGNORED 0x00008000 /* File was ignored */

    /// message sender (null for messages from OS)
    src: ?*edsm.StageMachine,
    /// message recipient (null will stop event loop)
    dst: ?*edsm.StageMachine,
    code: u8, // (row << 4) | col
    /// *EventSource for messages from OS (Tx, Sx, Dx, Fx),
    /// otherwise (Mx) pointer to some arbitrary data if needed
    ptr: ?*anyopaque,
};

pub const MessageQueue = RingBuffer(Message, 128);

pub const MessageDispatcher = struct {

    mq: *MessageQueue,
    eq: *ecap.EventQueue,

    pub fn init(mq: *MessageQueue, eq: *ecap.EventQueue) MessageDispatcher {
        return MessageDispatcher {
            .mq = mq,
            .eq = eq,
        };
    }

    /// message processing loop
    pub fn loop(self: *MessageDispatcher) !void {
        outer: while (true) {
            while (true) {
                const msg = self.mq.get() orelse break;
                if (msg.dst) |sm| {
                    sm.reactTo(msg);
                } else {
                    if (msg.src) |sm| {
                        if (sm.current_stage.leave) |bye| {
                            bye(sm);
                        }
                    }
                    break :outer;
                }
            }
            try self.eq.wait();
        }
    }
};
