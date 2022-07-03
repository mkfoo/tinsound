const std = @import("std");
const midi = @import("./midi.zig");
const Allocator = std.mem.Allocator;
const Endian = std.builtin.Endian;
const MidiSeq = midi.MidiSequencer;

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
            };
        }

        pub fn generate(self: *Self, writer: anytype, samples: usize) !void {
            const typ = Spec.sample_type;
            const end = Spec.endian;
            const max = std.math.maxInt(typ);
            var i: usize = 0;

            while (i < samples) : (i += 1) {
                var sample: f32 = 0.0;

                for (self.voices) |*voice| {
                    sample += voice.square();
                }

                const fmax = @intToFloat(f32, max);
                const val = @floatToInt(typ, fmax * sample * self.gain);
                try writer.writeInt(typ, val, end);
            }
        }

        pub fn render(self: *Self, writer: anytype) !void {
            var status: u8 = 0;

            while (status != midi.END_OF_TRACK) {
                self.midi.advance();

                while (self.midi.get_event()) |event| {
                    status = event.status;
                    if (status == midi.END_OF_TRACK) break;
                    std.debug.print("{} {} {}\n", .{ event.status, event.data1, event.data2 });
                    try self.generate(writer, 128);
                }
            }
        }
    };
}

const Voice = struct {
    sr: f32,
    cps: f32,
    phase: f32,

    const Self = @This();

    pub fn new(sr: f32) Self {
        return .{
            .sr = sr,
            .cps = 220,
            .phase = 0.0,
        };
    }

    pub fn square(self: *Self) f32 {
        self.phase += self.cps / self.sr;
        self.phase = @mod(self.phase, 1.0);
        const b: i32 = @boolToInt(self.phase < 0.5);
        return @intToFloat(f32, b * 2 - 1);
    }
};
