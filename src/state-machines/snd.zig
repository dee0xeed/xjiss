
const std = @import("std");
const os = std.os;
const mem = std.mem;
const math = std.math;
const print = std.debug.print;
const Allocator = std.mem.Allocator;

const mq = @import("../engine/message-queue.zig");
const MessageDispatcher = mq.MessageDispatcher;
const MessageQueue = MessageDispatcher.MessageQueue;
const Message = MessageQueue.Message;

const es = @import("../engine/event-sources.zig");
const EventSource = es.EventSource;

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

    const SoundData = struct {
        io: EventSource,
        jis: *Jis,
        handle: *alsa.snd_pcm_t,
        output: *alsa.snd_output_t,
        snd_buf: []i16,
        bsize: c_ulong,
        nframes: c_ulong,
    };

    pub fn onHeap(a: Allocator, md: *MessageDispatcher, jis: *Jis) !*StageMachine {

        var me = try StageMachine.onHeap(a, md, "SND", 1);
        try me.addStage(.{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(.{.name = "WORK", .enter = &workEnter, .leave = null});
        try me.addStage(.{.name = "FAIL", .enter = &failEnter, .leave = null});

        var init = &me.stages.items[0];
        var work = &me.stages.items[1];
        var fail = &me.stages.items[2];

        init.setReflex(.sm, Message.M0, .{.transition = work});
        work.setReflex(.io, Message.D1, .{.action = &workD1});
        work.setReflex(.io, Message.D2, .{.action = &workD2});
        work.setReflex(.sm, Message.M0, .{.transition = fail});
        fail.setReflex(.sm, Message.M0, .{.transition = work});

        me.data = me.allocator.create(SoundData) catch unreachable;
        var sd = util.opaqPtrTo(me.data, *SoundData);
        sd.jis = jis;
        return me;
    }

    fn initAlsa(sd: *SoundData) void {
        var buf: alsa.snd_pcm_uframes_t = undefined;
        var per: alsa.snd_pcm_uframes_t = undefined;
        var ret: c_int = 0;

        ret = pcmOpen(
            @ptrCast([*c]?*alsa.snd_pcm_t, @alignCast(@alignOf([*c]*alsa.snd_pcm_t), &sd.handle)),
            device, alsa.SND_PCM_STREAM_PLAYBACK, 0
        );
        if (ret < 0) {
            print("pcmOpen(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            unreachable;
        }

        ret = alsa.snd_output_stdio_attach(
            @ptrCast([*c]?*alsa.snd_output_t, @alignCast(@alignOf([*c]*alsa.snd_output_t), &sd.output)),
            alsa.stdout, 0
        );
        if (ret < 0) {
            print("{s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            unreachable;
        }

        ret = pcmSetParams(
            sd.handle,
            alsa.SND_PCM_FORMAT_S16, alsa.SND_PCM_ACCESS_RW_INTERLEAVED,
            2, sampling_rate, 0, latency
        );
        if (ret < 0) {
            print("pcmSetParams(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            unreachable;
        }

        _ = pcmDump(sd.handle, sd.output);
        _ = pcmGetParams(sd.handle, &buf, &per);
        sd.nframes = per;
    }

    fn initEnter(me: *StageMachine) void {
        var sd = util.opaqPtrTo(me.data, *SoundData);
        initAlsa(sd);
        sd.snd_buf = me.allocator.alloc(i16, 2 * sd.nframes) catch unreachable;
        mem.set(i16, sd.snd_buf, 0);
        me.initIo(&sd.io);
        me.msgTo(me, M0_WORK, null);
    }

    fn workEnter(me: *StageMachine) void {
        var sd = util.opaqPtrTo(me.data, *SoundData);
        var pcm_poll: alsa.pollfd = undefined;
        var ret: c_int = 0;

//        ret = pcmFdCount(sd.handle);
//        if (ret < 0) {
//            print("getPcmFdCount() failed: {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
//            me.msgTo(null, Message.M0, null);
//            return;
//        }

        ret = pcmFd(sd.handle, &pcm_poll, 1);
        if (ret < 0) {
            print("getPcmFd(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            me.msgTo(null, Message.M0, null);
            return;
        }

        sd.io.id = pcm_poll.fd;
        sd.io.enableOut(&me.md.eq) catch unreachable;
    }

    fn workD1(me: *StageMachine, _: ?*StageMachine, dptr: ?*anyopaque) void {

        var sd = util.opaqPtrTo(me.data, *SoundData);
        var io = util.opaqPtrTo(dptr, *EventSource);

        var ret = pcmWrite(sd.handle, sd.snd_buf.ptr, sd.nframes);
        if (ret < 0) {
            print("pcmWrite(): {s}\n", .{alsaStrErr(@intCast(c_int, ret))});
            me.msgTo(me, M0_FAIL, null);
            return;
        } else if (ret != sd.nframes) {
            print("pcmWrite(): partial write, {}/{} frames\n", .{ret, sd.nframes});
            me.msgTo(me, M0_FAIL, null);
            return;
        }

        sd.jis.generateWaveForm(sd.snd_buf);
        io.enableOut(&me.md.eq) catch unreachable;
    }

    fn workD2(me: *StageMachine, _: ?*StageMachine, _: ?*anyopaque) void {
        me.msgTo(me, M0_FAIL, null);
    }

    fn failEnter(me: *StageMachine) void {
        print("An error occured, recovering...\n", .{});
        var sd = util.opaqPtrTo(me.data, *SoundData);
        _ = pcmClose(sd.handle);
        initAlsa(sd);
        me.msgTo(me, M0_WORK, null);
    }
};
