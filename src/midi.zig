const std = @import("std");
const Allocator = std.mem.Allocator;

pub const NOTE_OFF: u8 = 0x80;
pub const NOTE_ON: u8 = 0x90;
pub const POLY_AFTERTOUCH: u8 = 0xa0;
pub const CONTROL_CHANGE: u8 = 0xb0;
pub const PROGRAM_CHANGE: u8 = 0xc0;
pub const CHANNEL_AFTERTOUCH: u8 = 0xd0;
pub const PITCH_BEND: u8 = 0xe0;
pub const SYSEX: u8 = 0xf0;
pub const EOX: u8 = 0xf7;
pub const TRACK_NUMBER: u8 = 0x00;
pub const TEXT_EVENT: u8 = 0x01;
pub const COPYRIGHT_NOTICE: u8 = 0x02;
pub const TRACK_NAME: u8 = 0x03;
pub const INSTRUMENT_NAME: u8 = 0x04;
pub const LYRIC: u8 = 0x05;
pub const MARKER: u8 = 0x06;
pub const CUE_POINT: u8 = 0x07;
pub const MIDI_CHANNEL_PREFIX: u8 = 0x20;
pub const END_OF_TRACK: u8 = 0x2f;
pub const SET_TEMPO: u8 = 0x51;
pub const SMPTE_OFFSET: u8 = 0x54;
pub const TIME_SIGNATURE: u8 = 0x58;
pub const KEY_SIGNATURE: u8 = 0x59;
pub const SEQUENCER_SPECIFIC: u8 = 0x7f;

pub const MidiError = error{
    InvalidChunkType,
    InvalidChunkLength,
    InvalidFormat,
    InvalidNumberOfTracks,
    InvalidTimeDiv,
};

pub const MidiHeader = struct {
    fmt: u16,
    ntrks: u16,
    div: u16,

    const Self = @This();

    pub fn new(reader: *Cursor) MidiError!Self {
        if (reader.read_u32() != 0x4d546864)
            return error.InvalidChunkType;

        if (reader.read_u32() != 6)
            return error.InvalidChunkLength;

        const fmt = reader.read_u16();

        if (fmt > 2)
            return error.InvalidFormat;

        const ntrks = reader.read_u16();

        if (ntrks == 0 or fmt == 0 and ntrks > 1)
            return error.InvalidNumberOfTracks;

        const div = reader.read_u16();

        if (div == 0)
            return error.InvalidTimeDiv;

        return Self{
            .fmt = fmt,
            .ntrks = ntrks,
            .div = div,
        };
    }
};

pub const MidiEvent = struct {
    status: u8,
    data1: u8 = 0,
    data2: u8 = 0,
};

pub const MidiTrack = struct {
    reader: Cursor,
    clock: u32,
    delta: u32,
    event: MidiEvent,

    const Self = @This();

    pub fn new(reader: *Cursor) MidiError!Self {
        if (reader.read_u32() != 0x4d54726b)
            return error.InvalidChunkType;

        const trk_len = reader.read_u32();

        if (trk_len == 0)
            return error.InvalidChunkLength;

        const trk_data = reader.slice(trk_len);

        var self = Self{
            .reader = Cursor.new(trk_data),
            .clock = 0,
            .delta = 0,
            .event = MidiEvent{
                .status = 0,
            },
        };

        self.read_next_event();
        return self;
    }

    pub fn advance(self: *Self) void {
        self.clock += 1;
    }

    pub fn get_event(self: *Self) ?MidiEvent {
        if (self.clock >= self.delta) {
            const event = self.event;

            if (event.status != END_OF_TRACK) {
                self.read_next_event();
            }

            return event;
        }

        return null;
    }

    fn read_next_event(self: *Self) void {
        self.clock = 0;
        self.delta = self.read_var_len();
        const byte0: u8 = self.reader.read_u8();

        switch (byte0) {
            0x00...0x7f => {
                self.event.data1 = byte0;
                self.read_cvm();
            },

            0x80...0xef => {
                self.event.status = byte0;
                self.event.data1 = self.reader.read_u8();
                self.read_cvm();
            },

            0xf0 => self.read_sysex(),

            0xf1...0xfe => {},

            0xff => self.read_meta(),
        }
    }

    fn read_cvm(self: *Self) void {
        switch (self.event.status & 0xf0) {
            NOTE_OFF, NOTE_ON, POLY_AFTERTOUCH, CONTROL_CHANGE, PITCH_BEND => {
                self.event.data2 = self.reader.read_u8();
            },
            else => {
                self.event.data2 = 0;
            },
        }
    }

    fn read_sysex(self: *Self) void {
        const len: u32 = self.read_var_len();
        self.reader.skip(len);
    }

    fn read_meta(self: *Self) void {
        self.event.status = self.reader.read_u8();
        self.event.data1 = 0;
        self.event.data2 = 0;
        const len: u32 = self.read_var_len();
        self.reader.skip(len);
    }

    fn read_var_len(self: *Self) u32 {
        var byte: u8 = self.reader.read_u8();
        var value: u32 = byte & 0x7f;

        while (byte & 0x80 != 0) {
            value <<= 7;
            byte = self.reader.read_u8();
            value += byte & 0x7f;
        }

        return value;
    }
};

pub const MidiSequencer = struct {
    header: MidiHeader,
    tracks: []MidiTrack,
    spt: u32,
    sc: u32,

    const Self = @This();
    const DefaultTempo: u32 = 500000;

    fn samples_per_tick(tempo_ms: u32, time_div: u16, smplrate: u32) u32 {
        const ms = @intToFloat(f32, tempo_ms);
        const div = @intToFloat(f32, time_div);
        const sr = @intToFloat(f32, smplrate);
        return @floatToInt(u32, ms / div / (1000000.0 / sr));
    }

    pub fn new(alloc: Allocator, sr: u32, mididata: []const u8) !Self {
        var reader = Cursor.new(mididata);
        const header = try MidiHeader.new(&reader);
        const tracks = try alloc.alloc(MidiTrack, header.ntrks);

        for (tracks) |*trk| {
            trk.* = try MidiTrack.new(&reader);
        }

        return Self{
            .header = header,
            .tracks = tracks,
            .spt = samples_per_tick(DefaultTempo, header.div, sr),
            .sc = 0,
        };
    }

    pub fn advance(self: *Self) void {
        self.sc += 1;

        if (self.sc == self.spt) {
            self.sc = 0;

            for (self.tracks) |*trk| {
                trk.advance();
            }
        }
    }

    pub fn get_event(self: *Self) ?MidiEvent {
        var at_end: u32 = 0;

        for (self.tracks) |*trk| {
            if (trk.get_event()) |event| {
                switch (event.status) {
                    END_OF_TRACK => at_end += 1,
                    else => return event,
                }
            }
        }

        if (at_end == self.tracks.len) {
            return MidiEvent{ .status = END_OF_TRACK };
        }

        return null;
    }
};

const Cursor = struct {
    cursor: usize,
    data: []const u8,

    const Self = @This();

    pub fn new(data: []const u8) Self {
        return Self{
            .cursor = 0,
            .data = data,
        };
    }

    pub fn skip(self: *Self, len: usize) void {
        self.cursor += len;
    }

    pub fn slice(self: *Self, len: usize) []const u8 {
        self.skip(len);
        return self.data[self.cursor - len .. self.cursor];
    }

    pub fn read_u8(self: *Self) u8 {
        self.skip(1);
        return self.data[self.cursor - 1];
    }

    pub fn read_u16(self: *Self) u16 {
        return std.mem.readIntSliceBig(u16, self.slice(2));
    }

    pub fn read_u32(self: *Self) u32 {
        return std.mem.readIntSliceBig(u32, self.slice(4));
    }
};

test "format0" {
    const FILE0 = [_]u8{
        0x4d, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x00, 0x00, 0x01, 0x00, 0x60, 0x4d,
        0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x3b, 0x00, 0xff, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08,
        0x00, 0xff, 0x51, 0x03, 0x07, 0xa1, 0x20, 0x00, 0xc0, 0x05, 0x00, 0xc1, 0x2e, 0x00, 0xc2,
        0x46, 0x00, 0x92, 0x30, 0x60, 0x00, 0x3c, 0x60, 0x60, 0x91, 0x43, 0x40, 0x60, 0x90, 0x4c,
        0x20, 0x81, 0x40, 0x82, 0x30, 0x40, 0x00, 0x3c, 0x40, 0x00, 0x81, 0x43, 0x40, 0x00, 0x80,
        0x4c, 0x40, 0x00, 0xff, 0x2f, 0x00,
    };

    const EXPECTED = [_]MidiEvent{
        MidiEvent{ .status = TIME_SIGNATURE },
        MidiEvent{ .status = SET_TEMPO },
        MidiEvent{
            .status = 0xc0,
            .data1 = 5,
        },
        MidiEvent{
            .status = 0xc1,
            .data1 = 46,
        },
        MidiEvent{
            .status = 0xc2,
            .data1 = 70,
        },
        MidiEvent{
            .status = 0x92,
            .data1 = 48,
            .data2 = 96,
        },
        MidiEvent{
            .status = 0x92,
            .data1 = 60,
            .data2 = 96,
        },
        MidiEvent{
            .status = 0x91,
            .data1 = 67,
            .data2 = 64,
        },
        MidiEvent{
            .status = 0x90,
            .data1 = 76,
            .data2 = 32,
        },
        MidiEvent{
            .status = 0x82,
            .data1 = 48,
            .data2 = 64,
        },
        MidiEvent{
            .status = 0x82,
            .data1 = 60,
            .data2 = 64,
        },
        MidiEvent{
            .status = 0x81,
            .data1 = 67,
            .data2 = 64,
        },
        MidiEvent{
            .status = 0x80,
            .data1 = 76,
            .data2 = 64,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    var seq = try MidiSequencer.new(allocator, 44100, &FILE0);
    try std.testing.expect(seq.header.fmt == 0);
    try std.testing.expect(seq.header.ntrks == 1);
    try std.testing.expect(seq.header.div == 96);
    try std.testing.expect(seq.spt == 229);
    var status: u8 = 0;
    var count: usize = 0;

    while (status != END_OF_TRACK) {
        seq.advance();

        while (seq.get_event()) |event| {
            status = event.status;
            if (status == END_OF_TRACK) break;
            const exp = EXPECTED[count];
            try std.testing.expect(event.status == exp.status);
            try std.testing.expect(event.data1 == exp.data1);
            try std.testing.expect(event.data2 == exp.data2);
            count += 1;
        }
    }

    arena.deinit();
}

test "format1" {
    const FILE1 = [_]u8{
        0x4d, 0x54, 0x68, 0x64, 0x00, 0x00, 0x00, 0x06, 0x00, 0x01, 0x00, 0x04, 0x00, 0x60, 0x4d,
        0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x14, 0x00, 0xff, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08,
        0x00, 0xff, 0x51, 0x03, 0x07, 0xa1, 0x20, 0x83, 0x00, 0xff, 0x2f, 0x00, 0x4d, 0x54, 0x72,
        0x6b, 0x00, 0x00, 0x00, 0x10, 0x00, 0xc0, 0x05, 0x81, 0x40, 0x90, 0x4c, 0x20, 0x81, 0x40,
        0x4c, 0x00, 0x00, 0xff, 0x2f, 0x00, 0x4d, 0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x0f, 0x00,
        0xc1, 0x2e, 0x60, 0x91, 0x43, 0x40, 0x82, 0x20, 0x43, 0x00, 0x00, 0xff, 0x2f, 0x00, 0x4d,
        0x54, 0x72, 0x6b, 0x00, 0x00, 0x00, 0x15, 0x00, 0xc2, 0x46, 0x00, 0x92, 0x30, 0x60, 0x00,
        0x3c, 0x60, 0x83, 0x00, 0x30, 0x00, 0x00, 0x3c, 0x00, 0x00, 0xff, 0x2f, 0x00,
    };

    const EXPECTED = [_]MidiEvent{
        MidiEvent{ .status = TIME_SIGNATURE },
        MidiEvent{ .status = SET_TEMPO },
        MidiEvent{
            .status = 0xc0,
            .data1 = 5,
        },
        MidiEvent{
            .status = 0xc1,
            .data1 = 46,
        },
        MidiEvent{
            .status = 0xc2,
            .data1 = 70,
        },
        MidiEvent{
            .status = 0x92,
            .data1 = 48,
            .data2 = 96,
        },
        MidiEvent{
            .status = 0x92,
            .data1 = 60,
            .data2 = 96,
        },
        MidiEvent{
            .status = 0x91,
            .data1 = 67,
            .data2 = 64,
        },
        MidiEvent{
            .status = 0x90,
            .data1 = 76,
            .data2 = 32,
        },
        MidiEvent{
            .status = 0x90,
            .data1 = 76,
        },
        MidiEvent{
            .status = 0x91,
            .data1 = 67,
        },
        MidiEvent{
            .status = 0x92,
            .data1 = 48,
        },
        MidiEvent{
            .status = 0x92,
            .data1 = 60,
        },
    };

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const allocator = arena.allocator();
    var seq = try MidiSequencer.new(allocator, 44100, &FILE1);
    try std.testing.expect(seq.header.fmt == 1);
    try std.testing.expect(seq.header.ntrks == 4);
    try std.testing.expect(seq.header.div == 96);
    try std.testing.expect(seq.spt == 229);
    var status: u8 = 0;
    var count: usize = 0;

    while (status != END_OF_TRACK) {
        seq.advance();

        while (seq.get_event()) |event| {
            status = event.status;
            if (status == END_OF_TRACK) break;
            const exp = EXPECTED[count];
            try std.testing.expect(event.status == exp.status);
            try std.testing.expect(event.data1 == exp.data1);
            try std.testing.expect(event.data2 == exp.data2);
            count += 1;
        }
    }

    arena.deinit();
}
