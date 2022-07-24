const std = @import("std");
const wav = @import("./wav.zig");
const syn = @import("./synth.zig");

const DefaultSpec = syn.AudioSpec.Default;
const WavFile = wav.WavFile;
const Synth = syn.Synth;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const midipath = try std.fmt.allocPrint(alloc, "{s}", .{std.os.argv[1]});
    const mididata = try std.fs.cwd().readFileAlloc(alloc, midipath, 1000000);
    const wavpath = try std.fmt.allocPrint(alloc, "{s}.wav", .{midipath});
    var wavfile = try WavFile.new(wavpath, &DefaultSpec);
    var writer = wavfile.writer();
    var synth = try Synth(&DefaultSpec, 3, 4).new(alloc);
    try synth.render_midi_file(&writer, mididata);
    try wavfile.finish();
    arena.deinit();
}
