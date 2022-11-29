
const std = @import("std");
const os = std.os;
const mem = std.mem;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const mq = @import("../engine/message-queue.zig");
const MessageDispatcher = mq.MessageDispatcher;
const MessageQueue = mq.MessageQueue;
const Message = mq.Message;
const es = @import("../engine/event-sources.zig");
const EventSource = es.EventSource;
const InOut = es.InOut;
const edsm = @import("../engine/edsm.zig");
const StageMachine = edsm.StageMachine;

const util = @import("../util.zig");
const Jis =  @import("../synt.zig").Jis;

const x11 = @cImport({
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/XKBlib.h");
});

pub const XjisGui = struct {

    const M0_WORK = Message.M0;
    const M0_SEND = Message.M0;
    const win_width: c_int = 584;
    const win_height: c_int = 204;
    const key_width: c_int = 40;

    pub const Mode = enum {
        server,
        client,
    };

    const eventHandlerFnPtr = *const fn(xe: *x11.XEvent, gd: *Data) bool;
    const funcKeyHandlerFnPtr = *const fn(jis: *Jis) bool;
    const Data = struct {
        io: InOut, // socket to X Server
        display: *x11.Display,
        window: x11.Window,
        screen: c_int,
        font_info: *x11.XFontStruct,
        gc: x11.GC,
        gc_vals: x11.XGCValues,
        fg_color: x11.XColor,
        pressed_key_color: x11.XColor,
        unpressed_key_color: x11.XColor,
        jis: *Jis,
        eventHandlers: [x11.LASTEvent]?eventHandlerFnPtr,
        funcKeysHandlers: [256]?funcKeyHandlerFnPtr,
        mode: Mode,
        sm: *StageMachine,
        client: ?*StageMachine,
    };

    sm: StageMachine,
    gd: Data,

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, jis: *Jis) !*XjisGui {

        var me = try a.create(XjisGui);
        me.sm = try StageMachine.init(a, md, "GUI", 1, 2);
        me.sm.stages[0] = .{.sm = &me.sm, .name = "INIT", .enter = &initEnter};
        me.sm.stages[1] = .{.sm = &me.sm, .name = "WORK", .enter = &workEnter};
        var init = &me.sm.stages[0];
        var work = &me.sm.stages[1];

        init.setReflex(Message.M0, .{.jump_to = work});
        work.setReflex(Message.D0, .{.do_this = &workD0});
        work.setReflex(Message.D2, .{.do_this = &workD2});
        work.setReflex(Message.M0, .{.do_this = &workM0});
        work.setReflex(Message.M1, .{.do_this = &workM1});

//        me.data = me.allocator.create(GuiData) catch unreachable;
//        var gd = util.opaqPtrTo(me.data, *GuiData);
        me.gd.jis = jis;
        me.gd.mode = .server;
        me.gd.client = null;
        me.gd.sm = &me.sm;

        for (me.gd.eventHandlers) |*h| { h.* = null;}
        me.gd.eventHandlers[x11.Expose] = &handleExpose;
        me.gd.eventHandlers[x11.ClientMessage] = &handleClientMessage;
        me.gd.eventHandlers[x11.KeyPress] = &handleKeyPress;
        me.gd.eventHandlers[x11.KeyRelease] = &handleKeyRelease;

        for (me.gd.funcKeysHandlers) |*h| { h.* = null;}
        me.gd.funcKeysHandlers[x11.XK_F1 & 0xFF] = &decreaseVolume;
        me.gd.funcKeysHandlers[x11.XK_F2 & 0xFF] = &increaseVolume;
        me.gd.funcKeysHandlers[x11.XK_F3 & 0xFF] = &onF3;
        me.gd.funcKeysHandlers[x11.XK_F4 & 0xFF] = &onF4;
        me.gd.funcKeysHandlers[x11.XK_F5 & 0xFF] = &onF5;
        me.gd.funcKeysHandlers[x11.XK_F6 & 0xFF] = &onF6;
        me.gd.funcKeysHandlers[x11.XK_F7 & 0xFF] = &onF7;
        me.gd.funcKeysHandlers[x11.XK_F8 & 0xFF] = &onF8;
        return me;
    }

    pub fn setMode(me: *XjisGui, mode: Mode) void {
        // var gd = util.opaqPtrTo(self.data, *GuiData);
        me.gd.mode = mode;
    }

    pub fn setBuddy(me: *XjisGui, other: *StageMachine) void {
        // var gd = util.opaqPtrTo(self.data, *GuiData);
        me.gd.client = other;
    }

    fn initX11(gd: *Data) !void {

        var win_name: x11.XTextProperty = undefined;
        var app_name = "Just Intonation Synthesizer";
        var wm_delwin: x11.Atom = undefined;
        var wm_hints: *x11.XWMHints = undefined;
        var class_hints: *x11.XClassHint = undefined;
        var size_hints: *x11.XSizeHints = undefined;
        const font_name = "9x15";
        var color: x11.XColor = undefined;

        gd.display = x11.XOpenDisplay(null).?;
        gd.screen = x11.DefaultScreen(gd.display);
        const dcm = x11.DefaultColormap(gd.display, @intCast(usize, gd.screen));
        _ = x11.XAllocNamedColor(gd.display, dcm, "SteelBlue", &gd.fg_color, &color);

        gd.window = x11.XCreateSimpleWindow(
            gd.display,
            x11.RootWindow(gd.display, @intCast(usize, gd.screen)), 0, 0,
            win_width, win_height, 3,
            x11.BlackPixel(gd.display, @intCast(usize, gd.screen)), 
            gd.fg_color.pixel
        );

        size_hints = x11.XAllocSizeHints();
        wm_hints = x11.XAllocWMHints();
        class_hints = x11.XAllocClassHint();

        size_hints.flags = x11.PSize | x11.PMinSize | x11.PMaxSize;
        size_hints.min_width = win_width;
        size_hints.min_height = win_height;
        size_hints.max_width = win_width;
        size_hints.max_height = win_height;

        _ = x11.XStringListToTextProperty(@ptrCast([*c][*c]u8, &app_name), 1, &win_name);

        wm_hints.initial_state = x11.NormalState;
        wm_hints.input = @as(c_int, 1);
        wm_hints.flags = x11.StateHint | x11.InputHint;

        class_hints.res_name = std.os.argv[0];
//        var class = "XJIS";
//        class_hints.res_class = @ptrCast([*c]u8, &class[0]);

        x11.XSetWMProperties (
                gd.display, gd.window,
                &win_name, null,
                @ptrCast([*c][*c]u8, std.os.argv), @intCast(c_int, std.os.argv.len),
                size_hints, wm_hints, class_hints
        );

        _ = x11.XSelectInput(
            gd.display, gd.window,
            x11.ExposureMask | x11.KeyPressMask | x11.ButtonPressMask | x11.KeyReleaseMask |
            x11.StructureNotifyMask
        );

        gd.font_info = x11.XLoadQueryFont(gd.display, font_name);
        gd.gc = x11.XCreateGC(gd.display, gd.window, 0, &gd.gc_vals);
        _ = x11.XSetFont(gd.display, gd.gc, gd.font_info.fid);

        wm_delwin = x11.XInternAtom(gd.display, "WM_DELETE_WINDOW", @as(c_int, 0));
        _ = x11.XSetWMProtocols(gd.display, gd.window, &wm_delwin, 1);
        _ = x11.XMapWindow(gd.display, gd.window);

        // keyboard controller generates events like this:
        // P p p p p ... R
        // X server adds "release" after each autorepeated "press":
        // P r p r p r p R
        // we do not want to have it like this here
        // after XkbSetDetectableAutoRepeat(1) we again have
        // P p p p p ... R
        const dar = x11.XkbSetDetectableAutoRepeat(gd.display, 1, null);
        if (1 != dar) {
            print("your system does not support DetectableAutoRepeat feature\n", .{});
            unreachable;
        }

        _ = x11.XAllocNamedColor(gd.display, dcm, "LemonChiffon", &gd.pressed_key_color, &color);
        _ = x11.XAllocNamedColor(gd.display, dcm, "gray", &gd.unpressed_key_color, &color);
    }

    fn handleExpose(e: *x11.XEvent, gd: *Data) bool {
        if (0 == e.xexpose.count)
            updateScreen(gd);
        return false;
    }

    fn handleClientMessage(xe: *x11.XEvent, gd: *Data) bool {
        _ = xe;
        _ = gd;
        // terminate
        return true;
    }

    fn decreaseVolume(jis: *Jis) bool {
        if (jis.amp > 100)
            jis.amp -= 10;
        print("amp = {}\n", .{jis.amp});
        return false;
    }

    fn increaseVolume(jis: *Jis) bool {
        if (jis.amp < 10000)
            jis.amp += 10;
        print("amp = {}\n", .{jis.amp});
        return false;
    }

    fn onF3(jis: *Jis) bool {
        // decrease sine fall off moment
        if (jis.timbre > 0.02)
            jis.timbre -= 0.01;
        print("timbre = {d:.2}\n", .{jis.timbre});
        return false;
    }

    fn onF4(jis: *Jis) bool {
        // increase sine fall off moment
        if (jis.timbre < 1.0)
            jis.timbre += 0.01;
        print("timbre = {d:.2}\n", .{jis.timbre});
        return false;
    }

    fn onF5(jis: *Jis) bool {
        const delta: u32 = if (jis.att < 100) 1 else 10;
        // decrease attack stage duration
        if (0 == jis.att_mask) {
            if (jis.att > 1)
                jis.att -= delta;
            print("attack = {} periods\n", .{jis.att});
        }
        return false;
    }

    fn onF6(jis: *Jis) bool {
        const delta: u32 = if (jis.att < 100) 1 else 10;
        // increase attack stage duration
        if (0 == jis.att_mask) {
            if (jis.att < 500)
                jis.att += delta;
            print("attack = {} periods\n", .{jis.att});
        }
        return false;
    }

    fn onF7(jis: *Jis) bool {
        const delta: u32 = if (jis.rel < 100) 1 else 10;
        // decrease release stage duration
        if (0 == jis.rel_mask) {
            if (jis.rel > 1)
                jis.rel -= delta;
            print("release = {} periods\n", .{jis.rel});
        }
        return false;
    }

    fn onF8(jis: *Jis) bool {
        const delta: u32 = if (jis.rel < 100) 1 else 10;
        // increase release stage duration
        if (0 == jis.rel_mask) {
            if (jis.rel < 1000)
                jis.rel += delta;
            print("release = {} periods\n", .{jis.rel});
        }
        return false;
    }

    fn toneOn(gd: *Data, tone_number: u6) void {
        const tn = &gd.jis.tones[tone_number];

        if (tn.is_active)
            return;
        if (tn.stage != .release)
            tn.phase = 0;
        if (.release == tn.stage)
            gd.jis.rel_mask &= ~(@as(u64, 1) << tone_number);

        tn.stage = .attack;
        tn.is_active = true;
        tn.nper = 0;
        gd.jis.att_mask |= (@as(u64, 1) << tone_number);

        updateKey(gd, tone_number);
        _ = x11.XFlush(gd.display);
    }

    fn handleKeyPress(e: *x11.XEvent, gd: *Data) bool {

        const ks = x11.XLookupKeysym(&e.xkey, 0);
        if ((ks & 0xFF00) != 0) {
            const handler = gd.funcKeysHandlers[ks & 0x00FF] orelse return false;
            return handler(gd.jis);
        }

        const tn = gd.jis.keyToToneNumber(@intCast(u8, ks & 0xFF)) orelse return false;
        if (.client == gd.mode) {
            const cmd = @intCast(u8, tn + 1) | 0x80;
            gd.sm.msgTo(gd.client, M0_SEND, @intToPtr(*anyopaque, cmd));
        }
        toneOn(gd, tn);
        return false;
    }

    fn toneOff(gd: *Data, tone_number: u6) void {
        const tone = &gd.jis.tones[tone_number];

        if (.attack == tone.stage)
            gd.jis.att_mask &= ~(@as(u64, 1) << tone_number);

        tone.stage = .release;
        tone.is_active = false;
        tone.nper = 0;
        gd.jis.rel_mask |= (@as(u64, 1) << tone_number);

        updateKey(gd, tone_number);
        _ = x11.XFlush(gd.display);
    }

    fn handleKeyRelease(xe: *x11.XEvent, gd: *Data) bool {

        const ks = x11.XLookupKeysym(&xe.xkey, 0);
        if (x11.XK_Escape == ks)
            return true;

        if (x11.XK_space == ks) {
            gd.jis.octave ^= 1;
            return false;
        }

        if ((ks & 0xFF00) != 0)
            return false;

        const tn = gd.jis.keyToToneNumber(@intCast(u8, ks & 0xFF)) orelse return false;
        if (.client == gd.mode) {
            const cmd = tn + 1;
            gd.sm.msgTo(gd.client, M0_SEND, @intToPtr(*anyopaque, cmd));
        }
        toneOff(gd, tn);
        return false;
    }

    fn updateKey(gd: *Data, tone_number: u6) void {
        const tn = gd.jis.tones[tone_number];
        const ti = Jis.scale[tone_number];
        var x: c_int = 0;
        var y: c_int = 0;

        x = key_width / 2 + ti.col * (key_width + 2) + ti.row * @divTrunc(key_width, 2);
        y = key_width / 2 + ti.row * (key_width + 2);

        _ = x11.XSetForeground(gd.display, gd.gc, gd.pressed_key_color.pixel);
        _ = x11.XDrawRectangle(gd.display, gd.window, gd.gc, x, y, key_width, key_width);
        if (tn.is_active) {
            _ = x11.XSetForeground(gd.display, gd.gc, gd.pressed_key_color.pixel);
            _ = x11.XFillRectangle(gd.display, gd.window, gd.gc, x + 2, y + 2, key_width - 2, key_width - 2);
        } else {
            _ = x11.XSetForeground(gd.display, gd.gc, gd.unpressed_key_color.pixel);
            _ = x11.XFillRectangle(gd.display, gd.window, gd.gc, x + 2, y + 2, key_width - 2, key_width - 2);
        }
        _ = x11.XSetForeground(gd.display, gd.gc, x11.BlackPixel(gd.display, @intCast(usize, gd.screen)));
        _ = x11.XDrawString (
                gd.display, gd.window, gd.gc,
                x + 5, y + key_width - 5,
                &ti.name[0], @intCast(c_int, ti.name.len)
        );
    }

    fn updateScreen(gd: *Data) void {
        for (gd.jis.tones) |_, k| {
            updateKey(gd, @intCast(u6, k));
        }
    }

    fn initEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(XjisGui, "sm", sm);
        initX11(&me.gd) catch unreachable;
        updateScreen(&me.gd);
        _ = x11.XFlush(me.gd.display);
        var id = x11.ConnectionNumber(me.gd.display);
        me.gd.io = InOut.init(&me.sm, id);
        sm.msgTo(sm, M0_WORK, null);
    }

    fn workEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(XjisGui, "sm", sm);
        me.gd.io.es.enable() catch unreachable;
    }

    fn workD0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var me = @fieldParentPtr(XjisGui, "sm", sm);
        var io = util.opaqPtrTo(dptr, *EventSource);

        while (x11.XPending(me.gd.display) != 0) {
            var xe: x11.XEvent = undefined;
            _ = x11.XNextEvent(me.gd.display, &xe);
            const handler = me.gd.eventHandlers[@intCast(usize, xe.type)] orelse continue;
            if (handler(&xe, &me.gd))
                sm.msgTo(null,  Message.M0, null);
        }
        io.enable() catch unreachable;
    }

    fn workD2(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        print("connection to X-server lost\n", .{});
        sm.msgTo(null, Message.M0, null);
    }

    // message from some server machine, turn a tone off
    fn workM0(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var me = @fieldParentPtr(XjisGui, "sm", sm);
        const tn = util.opaqPtrTo(dptr, *u8);
        toneOff(&me.gd, @intCast(u6, tn.*));
    }

    // message from some server machine, turn a tone on
    fn workM1(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        var me = @fieldParentPtr(XjisGui, "sm", sm);
        const tn = util.opaqPtrTo(dptr, *u8);
        toneOn(&me.gd, @intCast(u6, tn.*));
    }
};
