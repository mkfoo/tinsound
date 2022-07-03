const std = @import("std");
const AudioSpec = @import("./synth.zig").AudioSpec;

pub const WavHeader = packed struct {
    _riff: [4]u8 = [4]u8{ 'R', 'I', 'F', 'F' },
    file_size: u32 = 44,
    _wave: [4]u8 = [4]u8{ 'W', 'A', 'V', 'E' },
    _fmt: [4]u8 = [4]u8{ 'f', 'm', 't', ' ' },
    _fmt_size: u32 = 16,
    _fmt_type: u16 = 1,
    channels: u16,
    sample_rate: u32,
    avg_bits_per_sec: u32,
    block_align: u16,
    bits_per_sample: u16,
    _data: [4]u8 = [4]u8{ 'd', 'a', 't', 'a' },
    data_size: u32 = 0,

    const Self = @This();

    pub fn new(sr: u32, bps: u16, chns: u16) Self {
        const blkalign = chns * bps / 8;

        return .{
            .channels = chns,
            .sample_rate = sr,
            .avg_bits_per_sec = sr * blkalign,
            .block_align = blkalign,
            .bits_per_sample = bps,
        };
    }
};

pub const WavFile = struct {
    header: WavHeader,
    cw: std.io.CountingWriter(std.fs.File.Writer),

    const Self = @This();
    const WriterType = std.io.CountingWriter(std.fs.File.Writer).Writer;

    pub fn new(path: []const u8, comptime spec: *const AudioSpec) !Self {
        var file = try std.fs.cwd().createFile(path, .{});
        var fwriter = file.writer();
        try fwriter.writeByteNTimes(0, 44);

        return Self{
            .header = WavHeader.new(spec.sample_rate, spec.bits_per_sample, spec.channels),
            .cw = std.io.countingWriter(fwriter),
        };
    }

    pub fn writer(self: *Self) WriterType {
        return self.cw.writer();
    }

    pub fn finish(self: *Self) !void {
        const data_size = @intCast(u32, self.cw.bytes_written);
        self.header.data_size = data_size;
        self.header.file_size = data_size + 44;
        try self.cw.child_stream.context.seekTo(0);
        try self.cw.child_stream.writeStruct(self.header);
        self.cw.child_stream.context.close();
    }
};
