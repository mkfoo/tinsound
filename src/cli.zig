const std = @import("std");
const wav = @import("./wav.zig");
const synth = @import("./synth.zig");

const DefaultSpec = synth.AudioSpec.Default;
const WavFile = wav.WavFile;
const Synth = synth.Synth;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = arena.allocator();
    const midipath = try std.fmt.allocPrint(alloc, "{s}", .{std.os.argv[1]});
    const mididata = try std.fs.cwd().readFileAlloc(alloc, midipath, 1000000);
    const wavpath = try std.fmt.allocPrint(alloc, "{s}.wav", .{midipath});
    var wavfile = try WavFile.new(wavpath, &DefaultSpec);
    var writer = wavfile.writer();
    var s = try Synth(&DefaultSpec, 3).load(alloc, mididata);
    try s.render(&writer);
    try wavfile.finish();
    arena.deinit();
}
