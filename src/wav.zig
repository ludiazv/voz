const std = @import("std");

pub const wavHeader = extern struct {
    // RIFF Chunk Descriptor
    RIFF: [4]u8, // RIFF Header Magic header
    ChunkSize: u32, // RIFF Chunk Size
    WAVE: [4]u8, // WAVE Header
    // "fmt" sub-chunk
    fmt: [4]u8, // FMT header
    Subchunk1Size: u32, // Size of the fmt chunk
    AudioFormat: u16, // Audio format 1=PCM,6=mulaw,7=alaw,257=IBM Mu-Law, 258=IBM A-Law, 259=ADPCM
    NumOfChan: u16, // Number of channels 1=Mono 2=Stereo
    SamplesPerSec: u32, // Sampling Frequency in Hz
    bytesPerSec: u32, // bytes per second
    blockAlign: u16, // 2=16-bit mono, 4=16-bit stereo
    bitsPerSample: u16, // Number of bits per sample
    // "data" sub-chunk
    Subchunk2ID: [4]u8, // "data"  string
    Subchunk2Size: u32, // Sampled data length
};

pub const wavReader = struct {
    fd: std.fs.File,
    hdr: wavHeader,

    pub fn init(f: std.fs.File) !wavReader {
        //var fd_ = try std.fs.cwd().openFile(f, .{});
        //errdefer fd_.close();
        const hdr = try f.reader().readStruct(wavHeader);
        return wavReader{
            .fd = f,
            .hdr = hdr,
        };
    }

    pub inline fn writeHeader(self: *@This(), writer: anytype) !void {
        return writer.writeStruct(self.hdr);
    }

    pub inline fn nSamples(self: *const @This()) u32 {
        return self.hdr.Subchunk2Size / ((self.hdr.bitsPerSample / 8) * self.hdr.NumOfChan);
    }

    pub inline fn setHeaderSamples(self: *@This(), samples: u32) void {
        self.hdr.Subchunk2Size = samples * (self.hdr.bitsPerSample / 8) * self.hdr.NumOfChan;
    }

    pub fn details(self: *@This()) void {
        const h = &self.hdr;
        std.debug.print("WAV info:RIFF={s},WAVE={s},Format={d},Chanels={d},BPS={d},Rate={d},#Samples={d}\n", .{ h.RIFF, h.WAVE, h.AudioFormat, h.NumOfChan, h.bitsPerSample, h.SamplesPerSec, self.nSamples() });
    }

    pub inline fn read(self: *@This(), d: []i16) !usize {
        return self.fd.read(std.mem.sliceAsBytes(d));
    }

    pub fn isCompatible(self: *const @This()) bool {
        const h = &self.hdr;
        return h.AudioFormat == 1 and h.NumOfChan == 1 and h.SamplesPerSec == 16000 and h.bitsPerSample == 16 and
            h.Subchunk2ID[0] == 'd' and h.Subchunk2ID[3] == 'a';
    }
};
