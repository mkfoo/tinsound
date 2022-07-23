const std = @import("std");
const midi = @import("./midi.zig");
const Allocator = std.mem.Allocator;
const Endian = std.builtin.Endian;
const MidiSeq = midi.MidiSequencer;

const FTAB: [128]f32 = [_]f32{ 8.175799, 8.661957, 9.177024, 9.722718, 10.30086, 10.91338, 11.56233, 12.24986, 12.97827, 13.75, 14.56762, 15.43385, 16.3516, 17.32391, 18.35405, 19.44544, 20.60172, 21.82676, 23.12465, 24.49971, 25.95654, 27.5, 29.13524, 30.86771, 32.7032, 34.64783, 36.7081, 38.89087, 41.20344, 43.65353, 46.2493, 48.99943, 51.91309, 55.0, 58.27047, 61.73541, 65.40639, 69.29566, 73.41619, 77.78175, 82.40689, 87.30706, 92.49861, 97.99886, 103.8262, 110.0, 116.5409, 123.4708, 130.8128, 138.5913, 146.8324, 155.5635, 164.8138, 174.6141, 184.9972, 195.9977, 207.6523, 220.0, 233.0819, 246.9417, 261.6256, 277.1826, 293.6648, 311.127, 329.6276, 349.2282, 369.9944, 391.9954, 415.3047, 440.0, 466.1638, 493.8833, 523.2511, 554.3653, 587.3295, 622.254, 659.2551, 698.4565, 739.9888, 783.9909, 830.6094, 880.0, 932.3275, 987.7666, 1046.502, 1108.731, 1174.659, 1244.508, 1318.51, 1396.913, 1479.978, 1567.982, 1661.219, 1760.0, 1864.655, 1975.533, 2093.005, 2217.461, 2349.318, 2489.016, 2637.02, 2793.826, 2959.955, 3135.963, 3322.438, 3520.0, 3729.31, 3951.066, 4186.009, 4434.922, 4698.636, 4978.032, 5274.041, 5587.652, 5919.911, 6271.927, 6644.875, 7040.0, 7458.62, 7902.133, 8372.018, 8869.844, 9397.273, 9956.063, 10548.08, 11175.3, 11839.82, 12543.85 };

pub const AudioSpec = struct {
    sample_type: type,
    sample_rate: u32,
    bits_per_sample: u16,
    channels: u16,
    endian: Endian,

    const Self = @This();

    pub const Default = Self.new(i16, 44100, 1, Endian.Little);

    pub fn new(comptime T: type, sr: u32, chns: u16, end: Endian) Self {
        return .{
            .sample_type = T,
            .sample_rate = sr,
            .bits_per_sample = @bitSizeOf(T),
            .channels = chns,
            .endian = end,
        };
    }
};

pub fn Synth(comptime spec: *const AudioSpec, comptime nvoices: usize) type {
    return struct {
        gain: f32,
        midi: MidiSeq,
        voices: [nvoices]Voice,
        rem: u32,

        const Self = @This();
        pub const Spec = spec;

        pub fn load(alloc: Allocator, mididata: []const u8) !Self {
            const sr = @intToFloat(f32, Spec.sample_rate);

            return Self{
                .gain = 0.1,
                .midi = try MidiSeq.new(alloc, Spec.sample_rate, mididata),
                .voices = [_]Voice{
                    Voice.new(sr),
                    Voice.new(sr),
                    Voice.new(sr),
                },
                .rem = 0,
            };
        }

        pub fn generate(self: *Self, writer: anytype, samples: u32) !void {
            const typ = Spec.sample_type;
            const end = Spec.endian;
            const chs = Spec.channels;
            const max = std.math.maxInt(typ);
            var i: u32 = 0;

            while (i < samples) : (i += 1) {
                var sample: f32 = 0.0;

                for (self.voices) |*voice| {
                    sample += voice.square();
                }

                const fmax = @intToFloat(f32, max);
                const val = @floatToInt(typ, fmax * sample * self.gain);
                var j: u16 = 0;

                while (j < chs) : (j += 1) {
                    try writer.writeInt(typ, val, end);
                }
            }
        }

        pub fn render(self: *Self, writer: anytype, samples: u32) !bool {
            var rem = samples + self.rem;

            while (true) {
                while (self.midi.get_event()) |event| {
                    if (event.status == midi.END_OF_TRACK)
                        return false;

                    self.handle_event(event);
                }

                const adv = self.midi.advance(rem);
                try self.generate(writer, adv);
                rem -= adv;

                if (rem < self.midi.spt)
                    break;
            }

            self.rem = rem;
            return true;
        }

        pub fn render_all(self: *Self, writer: anytype) !void {
            var playing = true;

            while (playing) {
                playing = try self.render(writer, 1);
            }
        }

        fn handle_event(self: *Self, event: midi.MidiEvent) void {
            const typ: u8 = event.status & 0xf0;
            const chn: u8 = event.status & 0x0f;

            //std.debug.print("{x} {x} {x}\n", .{ event.status, event.data1, event.data2 });

            switch (typ) {
                midi.NOTE_OFF => {
                    self.voices[chn].vel = 0.0;
                },
                midi.NOTE_ON => {
                    self.voices[chn].cps = FTAB[event.data1];
                    self.voices[chn].vel = @intToFloat(f32, event.data2) / 255.0;
                },
                else => {},
            }
        }
    };
}

const Voice = struct {
    sr: f32,
    cps: f32,
    vel: f32,
    phase: f32,

    const Self = @This();

    pub fn new(sr: f32) Self {
        return .{
            .sr = sr,
            .cps = 220.0,
            .vel = 0.0,
            .phase = 0.0,
        };
    }

    pub fn square(self: *Self) f32 {
        self.phase += self.cps / self.sr;
        self.phase = @mod(self.phase, 1.0);
        const b: i32 = @boolToInt(self.phase < 0.5);
        return @intToFloat(f32, b * 2 - 1) * self.vel;
    }
};
