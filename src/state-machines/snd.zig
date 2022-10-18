
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
const Stage = StageMachine.Stage;
const Reflex = Stage.Reflex;

const util = @import("../util.zig");
const Jis =  @import("../synt.zig").Jis;

const alsa = @cImport({
    @cInclude("alsa/asoundlib.h");
    @cInclude("sys/poll.h");
});

pub const XjisSound = struct {

    const M0_WORK = Message.M0;
    const sampling_rate: c_int = 48000;
    const latency = 20000; // usec
    const device = "plughw:0,0";
    // const device = "default"; // does not work :(

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
        try me.addStage(Stage{.name = "INIT", .enter = &initEnter, .leave = null});
        try me.addStage(Stage{.name = "WORK", .enter = &workEnter, .leave = null});

        var init = &me.stages.items[0];
        var work = &me.stages.items[1];

        init.setReflex(.sm, Message.M0, Reflex{.transition = work});
        work.setReflex(.io, Message.D1, Reflex{.action = &workD1});
        work.setReflex(.io, Message.D2, Reflex{.action = &workD2});

        me.data = me.allocator.create(SoundData) catch unreachable;
        var sd = util.opaqPtrTo(me.data, *SoundData);
        sd.jis = jis;
        return me;
    }

    fn initAlsa(sd: *SoundData, a: Allocator) void {
        var buf: alsa.snd_pcm_uframes_t = undefined;
        var per: alsa.snd_pcm_uframes_t = undefined;
        var ret: c_int = 0;

        ret = alsa.snd_pcm_open(
            @ptrCast([*c]?*alsa.snd_pcm_t, @alignCast(@alignOf([*c]*alsa.snd_pcm_t), &sd.handle)),
            device, alsa.SND_PCM_STREAM_PLAYBACK, 0
        );
//        if (ret < 0) {
//            printf("ERR: %s() - snd_pcm_open() failed: %s\n", __func__, snd_strerror(ret));
//            exit(1);
//        }

//        ret = alsa.snd_output_stdio_attach(&sd.output, stdout, 0);
//        if (ret < 0) {
//            rintf("ERR: %s() - snd_output_stdio_attach() failed: %s\n", __func__, snd_strerror(ret));
//            exit(1);
//        }

        ret = alsa.snd_pcm_set_params(
            sd.handle,
            alsa.SND_PCM_FORMAT_S16, alsa.SND_PCM_ACCESS_RW_INTERLEAVED,
            2, sampling_rate, 0, latency
        );
//        if (ret < 0) {
//            printf("ERR: %s() - snd_pcm_set_params() failed: %s\n", __func__, snd_strerror(ret));
//            exit(1);
//        }

//        alsa.snd_pcm_dump(sd.handle, sd.output);
        _ = alsa.snd_pcm_get_params(sd.handle, &buf, &per);
        sd.nframes = per;
        sd.snd_buf = a.alloc(i16, 2 * sd.nframes) catch unreachable;
        mem.set(i16, sd.snd_buf, 0);
    }

    fn initEnter(me: *StageMachine) void {
        initAlsa(util.opaqPtrTo(me.data, *SoundData), me.allocator);
        me.msgTo(me, M0_WORK, null);
    }

    fn workEnter(me: *StageMachine) void {
        var sd = util.opaqPtrTo(me.data, *SoundData);
        var pcm_poll: alsa.pollfd = undefined;
        var ret: c_int = 0;

        ret = alsa.snd_pcm_poll_descriptors_count(sd.handle);

//        print("1. ret = {}\n", .{ret});
//        if (ret < 0) {
//            printf("ERR: %s() - snd_pcm_poll_descriptors_count() failed (%d): %s\n", __func__, ret, snd_strerror(ret));
//            exit(1);
//        }
//        if (ret != 1) {
//            printf("OPS: %s()  - more than one pcm fd (%d)\n", __func__, ret);
//            exit(1);
//        }

        ret = alsa.snd_pcm_poll_descriptors(sd.handle, &pcm_poll, 1);

//        print("2. ret = {}, fd = {}\n", .{ret, pcm_poll.fd});
//        if (ret < 0) {
//            printf("ERR: %s() - snd_pcm_poll_descriptors() failed: %s\n", __func__, snd_strerror(ret));
//            exit(1);
//        }

        me.initIo(&sd.io);
        sd.io.id = pcm_poll.fd;
        sd.io.enableOut(&me.md.eq) catch unreachable;
    }

    fn workD1(me: *StageMachine, _: ?*StageMachine, dptr: ?*anyopaque) void {

        var sd = util.opaqPtrTo(me.data, *SoundData);
        var io = util.opaqPtrTo(dptr, *EventSource);

        const ret = alsa.snd_pcm_writei(sd.handle, sd.snd_buf.ptr, sd.nframes);
        if (ret < 0) {
            _ = alsa.snd_pcm_prepare(sd.handle);
        }
//        if (ret != nframes) {
//            printf("OOPS: %s() - %d frames played out of %d\n", __func__, ret, nframes);
//            snd_pcm_prepare(handle);
//        }

        sd.jis.generateWaveForm(sd.snd_buf);
        io.enableOut(&me.md.eq) catch unreachable;
    }

    fn workD2(me: *StageMachine, _: ?*StageMachine, _: ?*anyopaque) void {
        var sd = util.opaqPtrTo(me.data, *SoundData);
        _ = sd;
    }
};
