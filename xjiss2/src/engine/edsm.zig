
const std = @import("std");
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const mq = @import("message-queue.zig");
const MessageDispatcher = mq.MessageDispatcher;
const MessageQueue = mq.MessageQueue;
const Message = mq.Message;

pub const StageMachine = struct {

    name: []const u8 = undefined,
    namebuf: [32]u8 = undefined,
    is_running: bool = false,
    stages: []Stage,
    current_stage: *Stage = undefined,
    md: *MessageDispatcher,
    allocator: Allocator,

    const Error = error {
        IsAlreadyRunning,
        HasNoStates,
        StageHasNoReflexes,
    };

    pub const Stage = struct {

        const reactFnPtr = *const fn(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void;
        const enterFnPtr = *const fn(sm: *StageMachine) void;
        const leaveFnPtr = enterFnPtr;

        const ReflexKind = enum {
            do_this,
            jump_to,
        };

        pub const Reflex = union(ReflexKind) {
            do_this: reactFnPtr,
            jump_to: *Stage,
        };

        /// number of rows in reflex matrix
        //const nrows = @typeInfo(EventSource.Kind).Enum.fields.len;
        const esk_tags = "MDSTF";
        const nrows = esk_tags.len;
        /// number of columns in reflex matrix
        const ncols = 16;
        /// name of a stage
        name: []const u8,
        /// called when machine enters a stage
        enter: ?enterFnPtr = null,
        /// called when machine leaves a stage
        leave: ?leaveFnPtr = null,

        /// reflex matrix
        /// row 0: M0 M1 M2 ... M15 : internal messages
        /// row 1: D0 D1 D2         : i/o (POLLIN, POLLOUT, POLLERR)
        /// row 2: S0 S1 S2 ... S15 : signals
        /// row 3: T0 T1 T2 ... T15 : timers
        /// row 4: F0 F1 F2.....F15 : file system events
        reflexes: [nrows][ncols]?Reflex = [nrows][ncols]?Reflex {
            [_]?Reflex{null} ** ncols,
            [_]?Reflex{null} ** ncols,
            [_]?Reflex{null} ** ncols,
            [_]?Reflex{null} ** ncols,
            [_]?Reflex{null} ** ncols,
        },

        sm: *StageMachine = undefined,

        pub fn setReflex(self: *Stage, code: u8, refl: Reflex) void {
            const row: u8 = code >> 4;
            const col: u8 = code & 0x0F;
            if (self.reflexes[row][col]) |_| {
                print("{s}/{s} already has relfex for '{c}{}'\n", .{self.sm.name, self.name, esk_tags[row], col});
                unreachable;
            }
            self.reflexes[row][col] = refl;
        }
    };

    pub fn init(a: Allocator, md: *MessageDispatcher, name: []const u8, number: u16, nstages: u4) !StageMachine {
        var sm = StageMachine {
            .md = md,
            .stages = try a.alloc(Stage, nstages),
            .allocator = a,
        };
        sm.name = try std.fmt.bufPrint(&sm.namebuf, "{s}-{}", .{name, number});
        return sm;
    }

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, name: []const u8, numb: u16, nstages: u4) !*StageMachine {
        var sm = try a.create(StageMachine);
        sm.* = try init(a, md, name, numb, nstages);
        return sm;
    }

    /// state machine engine
    pub fn reactTo(self: *StageMachine, msg: Message) void {
        const row = msg.code >> 4;
        const col = msg.code & 0x0F;

        const current_stage = self.current_stage;

        var sender = if (msg.src) |s| s.name else "OS";
        if (msg.src == self) sender = "SELF";

          // uncomment to see a workflow, very useful for debugging
//        print(
//            "{s} @ {s} got '{c}{}' from {s}\n",
//            .{self.name, current_stage.name, Stage.esk_tags[row], col, sender}
//        );

        if (current_stage.reflexes[row][col]) |refl| {
            switch (refl) {
                .do_this => |func| func(self, msg.src, msg.ptr),
                .jump_to => |next_stage| {
                    if (current_stage.leave) |func| {
                        func(self);
                    }
                    self.current_stage = next_stage;
                    if (next_stage.enter) |func| {
                        func(self);
                    }
                },
            }
        } else {
            print(
                "\n{s} @ {s} : no reflex for '{c}{}'\n",
                .{self.name, current_stage.name, Stage.esk_tags[row], col}
            );
            unreachable;
        }
    }

    pub fn msgTo(self: *StageMachine, dst: ?*StageMachine, code: u4, dptr: ?*anyopaque) void {
        const msg = Message {
            .src = self,
            .dst = dst,
            .code = code,
            .ptr = dptr,
        };
        // message buffer is not growable so this will panic
        // when there is no more space left in the buffer
        self.md.mq.put(msg) catch unreachable;
    }

    pub fn run(self: *StageMachine) !void {

        if (0 == self.stages.len)
            return Error.HasNoStates;
        if (self.is_running)
            return Error.IsAlreadyRunning;

        var k: u32 = 0;
        while (k < self.stages.len) : (k += 1) {
            const stage = &self.stages[k];
            var row: u8 = 0;
            var cnt: u8 = 0;
            while (row < Stage.nrows) : (row += 1) {
                var col: u8 = 0;
                while (col < Stage.ncols) : (col += 1) {
                    if (stage.reflexes[row][col] != null)
                        cnt += 1;
                }
            }
            if (0 == cnt) {
                print("stage '{s}' of '{s}' has no reflexes\n", .{stage.name, self.name});
                return Error.StageHasNoReflexes;
            }
        }

        self.current_stage = &self.stages[0];
        if (self.current_stage.enter) |hello| {
            hello(self);
        }
        self.is_running = true;
    }
};
