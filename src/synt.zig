
const std = @import("std");
const math = std.math;

pub const Jis = struct {

    const EnvelopStage = enum(u8) {
        silent,
        attack,
        decay,
        sustain,
        release,
    };

    pub const ToneInfo = struct {
        name: []const u8,
        row: c_int,
        col: c_int,
        period: u32,
    };

    pub const Tone = struct {
        phase: u32 = 0,
        stage: EnvelopStage = .silent,
        nper: u32 = 0,
        is_active: bool = false,
    };

    // DO NOT TOUCH UNLESS YOU UNDERSTAND WHAT YOU ARE DOING
    // @ SR = 48000 Hz gives 66.(6) Hz
    const root_tone_period: u32 = 720;
    const root = root_tone_period;
    const n_tones: u6 = 46;
    pub const scale: [n_tones]ToneInfo = [n_tones]ToneInfo {
        .{.name = "DO", .row = 3, .col =  0, .period = root},
        .{.name = "D+", .row = 2, .col =  0, .period = root * 17/18},
        .{.name = "R-", .row = 2, .col =  1, .period = root * 9/10},
        .{.name = "RE", .row = 3, .col =  1, .period = root * 8/9},
        .{.name = "MB", .row = 2, .col =  2, .period = root * 5/6},
        .{.name = "MI", .row = 3, .col =  2, .period = root * 4/5},
        .{.name = "M+", .row = 2, .col =  3, .period = root * 7/9},
        .{.name = "FA", .row = 3, .col =  3, .period = root * 3/4},
        .{.name = "F+", .row = 2, .col =  4, .period = root * 32/45},
        .{.name = "SO", .row = 3, .col =  4, .period = root * 2/3},
        .{.name = "LB", .row = 2, .col =  5, .period = root * 5/8},
        .{.name = "LA", .row = 3, .col =  5, .period = root * 3/5},
        .{.name = "SB", .row = 2, .col =  6, .period = root * 5/9},
        .{.name = "SI", .row = 3, .col =  6, .period = root * 8/15},
        .{.name = "Do", .row = 1, .col =  0, .period = root * 1/2},
        .{.name = "Do", .row = 3, .col =  7, .period = root * 1/2},
        .{.name = "D+", .row = 0, .col =  0, .period = root * 17/36},
        .{.name = "D+", .row = 2, .col =  7, .period = root * 17/36},
        .{.name = "R-", .row = 0, .col =  1, .period = root * 9/20},
        .{.name = "R-", .row = 2, .col =  8, .period = root * 9/20},
        .{.name = "Re", .row = 1, .col =  1, .period = root * 4/9},
        .{.name = "Re", .row = 3, .col =  8, .period = root * 4/9},
        .{.name = "Mb", .row = 0, .col =  2, .period = root * 5/12},
        .{.name = "Mb", .row = 2, .col =  9, .period = root * 5/12},
        .{.name = "Mi", .row = 1, .col =  2, .period = root * 2/5},
        .{.name = "Mi", .row = 3, .col =  9, .period = root * 2/5},
        .{.name = "M+", .row = 0, .col =  3, .period = root * 7/18},
        .{.name = "M+", .row = 2, .col = 10, .period = root * 7/18},
        .{.name = "Fa", .row = 1, .col =  3, .period = root * 3/8},
        .{.name = "F+", .row = 0, .col =  4, .period = root * 16/45},
        .{.name = "So", .row = 1, .col =  4, .period = root * 1/3},
        .{.name = "Lb", .row = 0, .col =  5, .period = root * 5/16},
        .{.name = "La", .row = 1, .col =  5, .period = root * 3/10},
        .{.name = "Sb", .row = 0, .col =  6, .period = root * 5/18},
        .{.name = "Si", .row = 1, .col =  6, .period = root * 4/15},
        .{.name = "do", .row = 1, .col =  7, .period = root * 1/4},
        .{.name = "d+", .row = 0, .col =  7, .period = root * 17/72},
        .{.name = "r-", .row = 0, .col =  8, .period = root * 9/40},
        .{.name = "re", .row = 1, .col =  8, .period = root * 2/9},
        .{.name = "mb", .row = 0, .col =  9, .period = root * 5/24},
        .{.name = "mi", .row = 1, .col =  9, .period = root * 1/5},
        .{.name = "m+", .row = 0, .col = 10, .period = root * 7/36},
        .{.name = "fa", .row = 1, .col = 10, .period = root * 3/16},
        .{.name = "f+", .row = 0, .col = 11, .period = root * 8/45},
        .{.name = "so", .row = 1, .col = 11, .period = root * 1/6},
        .{.name = "do", .row = 0, .col = 12, .period = root * 1/8},
    };

    key_to_tone_number_map: [256]?u6 = [_]?u6{null} ** 256,
    tones: [n_tones]Tone = [_]Tone{.{}} ** n_tones,

    timbre: f32 = 0.5,  // fraction of a period at which sine wave falls to zero
    amp: i32 = 3000,    // amplitude of pitches
    att: u32 = 5,       // attack duraton in periods
    att_mask: u64 = 0,  // pitches in ATTACK stage
    rel: u32 = 5,       // release duration in periods
    rel_mask: u64 = 0,  // pitches in RELEASE stage
    octave: u8 = 0,

    pub fn init() Jis {
        var jis = Jis{};
        jis.key_to_tone_number_map['z'] = 0;
        jis.key_to_tone_number_map['a'] = 1;
        jis.key_to_tone_number_map['s'] = 2;
        jis.key_to_tone_number_map['x'] = 3;
        jis.key_to_tone_number_map['d'] = 4;
        jis.key_to_tone_number_map['c'] = 5;
        jis.key_to_tone_number_map['f'] = 6;
        jis.key_to_tone_number_map['v'] = 7;
        jis.key_to_tone_number_map['g'] = 8;
        jis.key_to_tone_number_map['b'] = 9;
        jis.key_to_tone_number_map['h'] = 10;
        jis.key_to_tone_number_map['n'] = 11;
        jis.key_to_tone_number_map['j'] = 12;
        jis.key_to_tone_number_map['m'] = 13;
        jis.key_to_tone_number_map['q'] = 14;
        jis.key_to_tone_number_map[','] = 15;
        jis.key_to_tone_number_map['1'] = 16;
        jis.key_to_tone_number_map['k'] = 17;
        jis.key_to_tone_number_map['2'] = 18;
        jis.key_to_tone_number_map['l'] = 19;
        jis.key_to_tone_number_map['w'] = 20;
        jis.key_to_tone_number_map['.'] = 21;
        jis.key_to_tone_number_map['3'] = 22;
        jis.key_to_tone_number_map[';'] = 23;
        jis.key_to_tone_number_map['e'] = 24;
        jis.key_to_tone_number_map['/'] = 25;
        jis.key_to_tone_number_map['4'] = 26;
        jis.key_to_tone_number_map['\''] = 27;
        jis.key_to_tone_number_map['r'] = 28;
        jis.key_to_tone_number_map['5'] = 29;
        jis.key_to_tone_number_map['t'] = 30;
        jis.key_to_tone_number_map['6'] = 31;
        jis.key_to_tone_number_map['y'] = 32;
        jis.key_to_tone_number_map['7'] = 33;
        jis.key_to_tone_number_map['u'] = 34;
        jis.key_to_tone_number_map['i'] = 35;
        jis.key_to_tone_number_map['8'] = 36;
        jis.key_to_tone_number_map['9'] = 37;
        jis.key_to_tone_number_map['o'] = 38;
        jis.key_to_tone_number_map['0'] = 39;
        jis.key_to_tone_number_map['p'] = 40;
        jis.key_to_tone_number_map['-'] = 41;
        jis.key_to_tone_number_map['['] = 42;
        jis.key_to_tone_number_map['='] = 43;
        jis.key_to_tone_number_map[']'] = 44;
        jis.key_to_tone_number_map['\\']= 45;
        return jis;
    }

    pub fn generateWaveForm(jis: *@This(), buf: []i16) void {

        var k: u32 = 0;
        var i: u32 = 0;

        while (k < buf.len / 2) : (k += 1) {

            var s: i16 = 0;
            for (jis.tones) |*t, j| {

                var ti = &scale[j];
                var sj: i16 = 0;

                if (.silent == t.stage)
                    continue;

                var a = @intToFloat(f32, jis.amp);
                var o = @intToFloat(f32, jis.octave + 1);
                var b: u32 = @floatToInt(u32, jis.timbre * @intToFloat(f32, ti.period) / o);
                //var b: u32 = ti.period / o / 2;

                if (t.phase < b)
                    sj = @floatToInt(i16, a * math.sin(o * 2.0 * math.pi * @intToFloat(f32, t.phase) / @intToFloat(f32, ti.period)));

                if (.attack == t.stage) {
                    const x = (t.nper * ti.period + t.phase) / (jis.att * ti.period);
                    const m = @floatToInt(i16, 0.0 + @intToFloat(f32, x));
                    sj *= m;
                }
                if (.release == t.stage) {
                    const x = (t.nper * ti.period + t.phase)/(jis.rel * ti.period);
                    const m = @floatToInt(i16, 1.0 - @intToFloat(f32, x));
                    sj *= m;
                }

                s += sj;
                t.phase += 1;

                if (t.phase >= ti.period / @floatToInt(u32, o)) {

                    t.phase = 0;
                    t.nper += 1;

                    if (.release == t.stage) {
                        if (jis.rel == t.nper) {
                            t.stage = .silent;
                            t.nper = 0;
                            jis.rel_mask &= ~(@as(u64,1) << @intCast(u6, j));
                        }
                    }

                    if (.attack == t.stage) {
                        if (jis.att == t.nper) {
                            t.stage = .sustain;
                            t.nper = 0;
                            jis.att_mask &= ~(@as(u64,1) << @intCast(u6, j));
                        }
                    }
                }
            }

            i = k << 1;
            buf[i] = s;      // left channel
            buf[i + 1] = s;  // right channel
        }
    }
};
