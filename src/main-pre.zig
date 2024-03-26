//! This program is a simple CLI frontend for webrtc audio processing lib

const std = @import("std");
const clap = @import("clap");
const inputprocessor = @import("input-processor.zig");
const util = @import("util.zig");
const webrtc = inputprocessor.webrtc;
const wav = inputprocessor.wav;

const ll = std.log;

// Audio buffer is static
var audio_buffer: [inputprocessor.SAMPLES_40MS]i16 = undefined;

const args = clap.parseParamsComptime(
    \\-h, --help                Display this message.
    \\--version                 Show version.
    \\-a, --audio     <TYPE>    Audio in 'raw' or 'wav'. Samples must be PCM 16bit(LE) signed Mono. (default: raw)
    \\-o, --output    <TYPE>    Audio out 'raw' or 'wav'. (default: raw)
    \\-p, --preamp    <F>       Apply constant amplification factor.(float value). 1.0=disabled. (default: 1.0)
    \\-n, --noiser    <U>       Apply noise reduction preprocessing to audio input on a 0 to scale. 0=disabled 4=max (default:disabled)
    \\-g, --autogain  <U>       Apply auto gain filter 0..31. 0=disabled. (default: disabled)
    \\-d, --vad                 Enable VAD detection. (default: disabled)
    \\-t, --timming             Measure processing time in ms. (default: disabled)
);

const some_help =
    \\ This program process an audito stream that is read from standard input and writes out the processed audio to the processed audio stream.
    \\ Audio is read in 40ms chunks and acepts only PCM signed 16bit(LE) input streams.
    \\ 
    \\ The audio input could be processed with 3 parameters (disabled by default):
    \\
    \\ --preamp: apply a constant factor to each sample of the input. e.g. a value of 2 will double the volume of the input
    \\ --noiser: apply a noise reduction algorthim with a streng factor 0=disabled 4=max.
    \\ --autogain: apply auto gain. 0=disbaled 31=31dbfs
    \\
    \\ VAD:
    \\
    \\ --vad: Perform voice activity detection.
    \\ 
    \\ The preprocessor will prepend a byte to the output with 0 or 0x01-0x0F indicating a possible VAD in the chuck. 
    \\ This parameter is ignored if --outaudio=wav and will not perform any vad detection.
    \\ 
    \\ All audio processing can cause distorssion on the signal and must be tunned to obtain better results.
;

const args_parsers = .{
    .TYPE = clap.parsers.enumeration(inputprocessor.InputType),
    .N = clap.parsers.int(u32, 10),
    .U = clap.parsers.int(u8, 10),
    .F = clap.parsers.float(f32),
};

const ArgsType = clap.Result(clap.Help, &args, args_parsers);

/// Parse program arguments
fn parseArgs(alloc: std.mem.Allocator) !ArgsType {
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &args, args_parsers, .{
        .diagnostic = &diag,
        .allocator = alloc,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        return err;
    };
    return res;
}

pub fn main() !u8 {
    const stdout = std.io.getStdOut();
    const stderr = std.io.getStdErr();
    const source = std.io.getStdIn();

    // Init GPA
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    //

    // Parse arguments
    const arg = try parseArgs(allocator);
    defer arg.deinit();
    //

    // Print help
    if (arg.args.help != 0) {
        try stdout.writer().print("voz-pre - A simple audio cli processor for voice\n", .{});
        try clap.help(stdout.writer(), clap.Help, &args, .{});
        try stdout.writer().print("\n{s}\n", .{some_help});
        return 0;
    }
    // Print version
    if (arg.args.version != 0) {
        stdout.writer().print("{s}\n", .{util.VOZ_VERSION}) catch unreachable;
        return 0;
    }

    // Gest input parameters
    const typ = arg.args.audio orelse .raw;
    const timming = arg.args.timming != 0;
    const typ_out = arg.args.output orelse .raw;
    const preamp = arg.args.preamp orelse 1.0;
    const ns_level = arg.args.noiser orelse 0;
    const auto_gain = arg.args.autogain orelse 0;
    const vad = if (typ == .wav) false else arg.args.vad != 0;

    // Create the preprocessor.
    var pre = inputprocessor.InputProcessor.createPreprocessor(ns_level, auto_gain, preamp, vad);
    if (pre == null) ll.warn("Audio processor features not selected. The ouput will be equal to the input", .{});

    // check wav compatibility
    // -----
    if (typ == .wav) {
        var w = wav.wavReader.init(source) catch |err| {
            ll.err("could not read wav header => {}", .{err});
            return 1;
        };
        if (w.isCompatible()) {
            w.details();
            const read_chunks = w.nSamples() / @as(u32, audio_buffer.len);
            ll.info("wav will read {d} chucks\n", .{read_chunks});
            if (typ_out == .wav) {
                w.setHeaderSamples(read_chunks * @as(u32, @intCast(audio_buffer.len)));
                try w.writeHeader(stdout.writer());
            }
        } else {
            ll.err("wav format incorrect or not compatible. WAV must be 16Khz PCM signed 16-bit mono", .{});
            return 2;
        }
    }

    ll.info("Starting voz audio processor...", .{});

    // Main loop
    var keep_running = true;
    var audio_as_bytes = std.mem.sliceAsBytes(&audio_buffer); // audio buffer as byte buffer
    const chunk_bytes = audio_buffer.len * @sizeOf(i16); // audio buffer size in bytes
    var total_chunks: u64 = 0;
    var timer = if (timming) try std.time.Timer.start() else null;
    var r_avg: u64 = 0; // rolling timming average;

    while (keep_running) {
        var readed_bytes: usize = 0;
        // inner loop to fill the audio buffer
        while (keep_running and readed_bytes < chunk_bytes) {
            const n = std.os.read(source.handle, audio_as_bytes[readed_bytes..]) catch |err| {
                ll.err("I/O error reading audio=>{any}", .{err});
                return 3; //aborting reads
            };
            if (n == 0) keep_running = false; //EOF
            if (n > 0) readed_bytes += n;
        } // Fill the audio buffer to chuck_size

        // At this point the audiobuffer is full or EOF reached.
        if (readed_bytes == chunk_bytes) {
            if (timer) |*t| t.reset();
            const vadresult = if (pre) |pr| inputprocessor.InputProcessor.preporcessAudio(pr, &audio_buffer, 4) else 0;
            if (vad) {
                _ = std.os.write(stdout.handle, &[_]u8{vadresult}) catch |err| {
                    ll.err("I/O error writing audio=>{any}", .{err});
                    return 3;
                };
            }
            const n = std.os.write(stdout.handle, audio_as_bytes) catch |err| {
                ll.err("I/O error writing audio=>{any}", .{err});
                return 3;
            };
            if (timer) |*t| r_avg = (r_avg + t.read()) / 2;
            if (n != chunk_bytes) ll.warn("Partial write of chunck readed={d},written={}", .{ readed_bytes, n });
            total_chunks +%= 1;
        }
    }

    if (pre) |p| inputprocessor.InputProcessor.destroyPreprocessor(p); // Destroys the preprocesor if needed.
    try stderr.writer().print("oww-mini-pre finished. total chucks processed={d} , rolling avg processing={d}ms\n", .{ total_chunks, r_avg / std.time.ns_per_ms });
    return 0;
}
