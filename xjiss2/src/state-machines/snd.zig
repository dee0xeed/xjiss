
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

const alsa = @cImport({
    @cInclude("alsa/asoundlib.h");
    @cInclude("sys/poll.h");
    @cInclude("stdio.h");
});
const pcmOpen = alsa.snd_pcm_open;
const pcmSetParams = alsa.snd_pcm_set_params;
const pcmDump = alsa.snd_pcm_dump;
const pcmGetParams = alsa.snd_pcm_get_params;
const pcmFdCount = alsa.snd_pcm_poll_descriptors_count;
const pcmFd = alsa.snd_pcm_poll_descriptors;
const pcmWrite = alsa.snd_pcm_writei;
const pcmClose = alsa.snd_pcm_close;
const alsaStrErr = alsa.snd_strerror;

pub const XjisSound = struct {

    const M0_WORK = Message.M0;
    const M0_FAIL = Message.M0;

    const sampling_rate: c_int = 48000;
    const latency = 20000; // usec
    // const device = "hw:0,0";
    const device = "plughw:0,0";

    const Data = struct {
        io: InOut,
        jis: *Jis,
        handle: *alsa.snd_pcm_t,
        output: *alsa.snd_output_t,
        snd_buf: []i16,
        bsize: c_ulong,
        nframes: c_ulong,
    };

    sm: StageMachine,
    sd: Data,

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, jis: *Jis) !*XjisSound {

        var me = try a.create(XjisSound);
        me.sm = try StageMachine.init(a, md, "SND", 1, 3);
        me.sm.stages[0] = .{.sm = &me.sm, .name = "INIT", .enter = &initEnter};
        me.sm.stages[1] = .{.sm = &me.sm, .name = "WORK", .enter = &workEnter};
        me.sm.stages[2] = .{.sm = &me.sm, .name = "FAIL", .enter = &failEnter};

        var init = &me.sm.stages[0];
        var work = &me.sm.stages[1];
        var fail = &me.sm.stages[2];

        init.setReflex(Message.M0, .{.jump_to = work});
        work.setReflex(Message.D1, .{.do_this = &workD1});
        work.setReflex(Message.D2, .{.do_this = &workD2});
        work.setReflex(Message.M0, .{.jump_to = fail});
        fail.setReflex(Message.M0, .{.jump_to = work});

        me.sd.jis = jis;
        return me;
    }

    fn initAlsa(sd: *Data) void {
        var buf: alsa.snd_pcm_uframes_t = undefined;
        var per: alsa.snd_pcm_uframes_t = undefined;
        var ret: c_int = 0;

        ret = pcmOpen(
            @ptrCast([*c]?*alsa.snd_pcm_t, @alignCast(@alignOf([*c]*alsa.snd_pcm_t), &sd.handle)),
            device, alsa.SND_PCM_STREAM_PLAYBACK, 0
        );
        if (ret < 0) {
            print("pcmOpen(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            os.raise(os.SIG.TERM) catch unreachable;
        }

        ret = alsa.snd_output_stdio_attach(
            @ptrCast([*c]?*alsa.snd_output_t, @alignCast(@alignOf([*c]*alsa.snd_output_t), &sd.output)),
            alsa.stdout, 0
        );
        if (ret < 0) {
            print("{s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            os.raise(os.SIG.TERM) catch unreachable;
        }

        ret = pcmSetParams(
            sd.handle,
            alsa.SND_PCM_FORMAT_S16, alsa.SND_PCM_ACCESS_RW_INTERLEAVED,
            2, sampling_rate, 0, latency
        );
        if (ret < 0) {
            print("pcmSetParams(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            os.raise(os.SIG.TERM) catch unreachable;
        }

        _ = pcmDump(sd.handle, sd.output);
        _ = pcmGetParams(sd.handle, &buf, &per);
        sd.nframes = per;
    }

    fn initEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(XjisSound, "sm", sm);
        initAlsa(&me.sd);
        me.sd.snd_buf = sm.allocator.alloc(i16, 2 * me.sd.nframes) catch unreachable;
        mem.set(i16, me.sd.snd_buf, 0);
        me.sd.io = InOut.init(&me.sm, -1);
        sm.msgTo(sm, M0_WORK, null);
    }

    fn workEnter(sm: *StageMachine) void {
        var me = @fieldParentPtr(XjisSound, "sm", sm);
        var pcm_poll: alsa.pollfd = undefined;
        var ret: c_int = 0;

        ret = pcmFdCount(me.sd.handle);
        if (ret < 0) {
            print("getPcmFdCount(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            os.raise(os.SIG.TERM) catch unreachable;
            return;
        }
        if (ret != 1) {
            print("getPcmFdCount(): we want only 1 fd\n", .{});
            os.raise(os.SIG.TERM) catch unreachable;
            return;
        }
        ret = pcmFd(me.sd.handle, &pcm_poll, 1);
        if (ret < 0) {
            print("getPcmFd(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            os.raise(os.SIG.TERM) catch unreachable;
            return;
        }
        me.sd.io.es.id = pcm_poll.fd;
        me.sd.io.enableOut() catch unreachable;
    }

    fn workD1(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        var me = @fieldParentPtr(XjisSound, "sm", sm);

        var ret = pcmWrite(me.sd.handle, me.sd.snd_buf.ptr, me.sd.nframes);
        if (ret < 0) {
            print("pcmWrite(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            sm.msgTo(sm, M0_FAIL, null);
            return;
        } else if (ret != me.sd.nframes) {
            print("pcmWrite(): partial write, {}/{} frames\n", .{ret, me.sd.nframes});
            sm.msgTo(sm, M0_FAIL, null);
            return;
        }

        me.sd.jis.generateWaveForm(me.sd.snd_buf);
        me.sd.io.enableOut() catch unreachable;
    }

    fn workD2(sm: *StageMachine, src: ?*StageMachine, dptr: ?*anyopaque) void {
        _ = src;
        _ = dptr;
        sm.msgTo(sm, M0_FAIL, null);
    }

    fn failEnter(sm: *StageMachine) void {
        print("An error occured, recovering...\n", .{});
        var me = @fieldParentPtr(XjisSound, "sm", sm);
        _ = pcmClose(me.sd.handle);
        initAlsa(&me.sd);
        sm.msgTo(sm, M0_WORK, null);
    }
};
