const std = @import("std");
const clap = @import("clap");
const inputprocessor = @import("input-processor.zig");
const audiofeatures = @import("audio-features.zig");
const wakeword = @import("wakeword.zig");
const util = @import("util.zig");

const rollbuffer = @import("rollbuffer.zig");
const log = std.log;

pub const log_level: std.log.Level = .debug;

const no_mamed_model = "no_name";

const args = clap.parseParamsComptime(
    \\-h, --help                Display this message.
    \\--version                 Show version.
    \\--bench         <N>       Run the wakeword processing benchmark fon N times
    \\-a, --audio     <ATYPE>   Source of the audio 'raw' or 'wav'. Samples must be PCM 16bit(LE) signed Mono.
    \\-o, --output    <OTYPE>   Ouput format [human,machine,json]. Defaults to json
    \\-s, --sync                Process audio as audio rate. This is necessary if the source produces samples at a fast rate. (use this for wavs)
    \\-p, --preamp    <F>       Apply constant audio pre amplification factor.(float value). 1=disabled.
    \\-n, --noiser    <U>       Apply noise reduction preprocessing to audio input on a 0 to scale. 0=disabled 4=max
    \\-g, --autogain  <U>       Apply auto gain filter 0..31dbFS. 0=disabled.
    \\-m, --modelsdir <PATH>    Path to base models directory. defaults=<exe-dir>/models
    \\<MODELSPEC>...
);

const some_help =
    \\ This program is a simple inference engine to detect wakewords using openwakeword models.
    \\ It takes raw audio from the standard input and writes out to the standard output if the prediction matched the specified criteria.
    \\
    \\ The software is designed to work in streaming mode. For testing the options --audio(-a) wav that must be used with --sync option.
    \\ 
    \\ The audio input could be preprocessed with 3 parameters (disbled by default):
    \\ --preamp: apply a constant factor to each sample of the input. e.g. a value of 2 will double the volume of the input
    \\ --noiser: apply a noise reduction algorthim. 
    \\ --autogain: apply auto gain.
    \\ 
    \\ All audio processing can cause distorssion on the signal and must be tunned to obtain better results.
    \\
    \\ <MODELSPEC> should be provided as wakeword's_model_path:wakeword_name(string):threshold(float):patience(int)
    \\ Several wakeword models can be used at the same time. 
;

const args_parsers = .{
    .ATYPE = clap.parsers.enumeration(inputprocessor.InputType),
    .OTYPE = clap.parsers.enumeration(util.OuputFormat),
    .N = clap.parsers.int(u32, 10),
    .U = clap.parsers.int(u8, 10),
    .F = clap.parsers.float(f32),
    .MODELSPEC = clap.parsers.string,
    .PATH = clap.parsers.string,
};

const ArgsType = clap.Result(clap.Help, &args, args_parsers);

/// Parese program arguments
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

/// Decode model params with the following format model_path:name:threshold(f32):patience(usize)
fn decodeModelParam(allocator: std.mem.Allocator, m: []const u8) !wakeword.WakeWordConfig {

    // Slit all into pars array list.
    var pars = try std.ArrayList([]const u8).initCapacity(allocator, 4);
    defer pars.deinit();
    var it = std.mem.splitScalar(u8, m, ':'); // Split iterator
    while (it.next()) |e| try pars.append(e);

    // parse the params
    const itm = pars.items;
    const model_path = if (itm.len > 0) pars.items[0] else unreachable;
    const name = if (itm.len > 1) itm[1] else no_mamed_model;
    const th = if (itm.len > 2) try std.fmt.parseFloat(f32, itm[2]) else 0.5;
    const pa = if (itm.len > 3) try std.fmt.parseInt(u32, itm[3], 10) else 1;

    // HACK change the first ':' for \0 to make this slice to play well with C strings. Model path is used in a C Call
    var mo = @constCast(m); // Ugly cast to remove const but necessary for the hack.
    if (std.mem.indexOfScalar(u8, mo, ':')) |pos| mo[pos] = '\x00';

    return wakeword.WakeWordConfig{
        .name = name,
        .model_path = @ptrCast(model_path),
        .threshold = th,
        .patience = pa,
    };
}

pub fn main() !u8 {
    const stdout = std.io.getStdOut();

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
        try stdout.writer().print("voz-oww - A simple wakeword detector\n", .{});
        try clap.help(stdout.writer(), clap.Help, &args, .{});
        try stdout.writer().print("\n{s}\n", .{some_help});
        return 0;
    }
    // Print version
    if (arg.args.version != 0) {
        stdout.writer().print("{s}\n", .{util.VOZ_VERSION}) catch unreachable;
        return 0;
    }
    // check at least one wakeword model is provided.
    if (arg.positionals.len == 0) {
        try std.io.getStdErr().writer().print("At least one wakeword model is required. use -h for help\n", .{});
        return 1;
    }
    // Parse wakeword specs
    var wake_words_ar = try std.ArrayList(wakeword.WakeWordConfig).initCapacity(allocator, arg.positionals.len);
    for (arg.positionals) |m| {
        const cfg = try decodeModelParam(allocator, m);
        try wake_words_ar.append(cfg);
    }
    // We need only a slice, we drop the array list and onw the slice.
    const wake_words_config = try wake_words_ar.toOwnedSlice();
    defer allocator.free(wake_words_config);

    // Main program
    var pred_rb = try wakeword.PredicionType.init(allocator, 5, false); // init the prediction rollbuffer. This is the output of the models.
    defer pred_rb.deinit();

    var ww = try wakeword.WakeWord.init(allocator, wake_words_config, &pred_rb); // init the wakeword predictor passing configs and the output buffer.
    defer ww.deinit();

    // init Audio feaatures engine pasing the models location and the output buffer(which is the ww model input)
    const mel_model = try if (arg.args.modelsdir) |m| util.customPath(allocator, m, "melspectrogram.tflite") else util.absPathExe(allocator, "models", "melspectrogram.tflite");
    const emb_model = try if (arg.args.modelsdir) |m| util.customPath(allocator, m, "embedding_model.tflite") else util.absPathExe(allocator, "models", "embedding_model.tflite");
    errdefer allocator.free(mel_model);
    errdefer allocator.free(emb_model);
    var af = try audiofeatures.AudioFeatures.init(allocator, mel_model, emb_model, ww.getFeaturesBuffer());
    defer af.deinit();
    allocator.free(mel_model);
    allocator.free(emb_model); // Not needed anymore.

    // init input processor engine pasing the audio buffer as output the chunk sise and
    const preamp = arg.args.preamp orelse 1;
    const ns_level = arg.args.noiser orelse 0;
    const auto_gain = arg.args.autogain orelse 0;
    var ip = try inputprocessor.InputProcessor.init(allocator, af.getAudioBuffer(), audiofeatures.chunk_size, ns_level, auto_gain, preamp, false);
    defer ip.deinit();

    if (arg.args.bench) |n| {
        try stdout.writer().print("Benchmarking wakeword detection models for {d} rounds...\n", .{n});
        const ip_bench = try ip.bench(@as(usize, n), @as(u64, audiofeatures.frame_chunks));
        const af_bench = try af.bench(@as(usize, n));
        const ww_bench = try ww.bench(@as(usize, n), @as(u64, audiofeatures.frame_chunks));
        const total = af_bench + ww_bench + ip_bench;
        try stdout.writer().print("Total average time for processing audio frames:{d:.2}ms.\n", .{total});
        var required: f32 = @as(f32, @floatFromInt(audiofeatures.frame_size)) / @as(f32, @floatFromInt(audiofeatures.SR));
        required *= 1000.0 * 0.85; // This is the length 85% of the length of a frame. The models need to run faster than this to process audio in realtime.

        try stdout.writer().print("To work stable this number has to be < than {d:.2}ms.\n", .{required});
        return 0;
    }

    // Start the ww thread first
    var ww_thread = try ww.start();
    // Start the audiofeatures thread
    var af_thread = try af.start();
    // Start the audio capture thread
    const audio_type = arg.args.audio orelse .raw;
    var audio_thread = try ip.start(audio_type, std.io.getStdIn(), arg.args.sync != 0);
    //var audio_thread = try inputprocessor.start(allocator, audio_type, af.getAudioBuffer(), audiofeatures.chunk_size, arg.args.sync != 0);

    // register control callbacks
    global_input_processor = &ip;
    try util.registerSignal(std.os.SIG.TERM, handleSignals);
    try util.registerSignal(std.os.SIG.INT, handleSignals);
    try util.registerSignal(std.os.SIG.USR1, handleSignals);
    log.info("Registered signals TERM, INT and USR1", .{});

    // Main predicion loop
    var keep_running = true;
    const output_format = arg.args.output orelse .json;
    var writer = stdout.writer();
    ReadyEvent.Ready.print(output_format, writer) catch unreachable;
    while (keep_running) {
        var lrb = pred_rb.waitAny();
        keep_running = !lrb.status().cancel;
        while (lrb.len() > 0) {
            const p = lrb.get()[0];
            p.print(output_format, writer) catch {};
            lrb.roll(1);
        }
        lrb.release();
    }

    ReadyEvent.NotReady.print(output_format, writer) catch unreachable;
    // Wait for threads to finish in order.
    audio_thread.join();
    af_thread.join();
    ww_thread.join();

    log.info("Finished", .{});

    return 0;
}

var global_input_processor: ?*inputprocessor.InputProcessor = null;

fn handleSignals(sig: c_int) callconv(.C) void {
    if (global_input_processor) |ip| {
        switch (sig) {
            std.os.SIG.TERM, std.os.SIG.INT => {
                ip.stop();
                log.info("Termination Signal {d} received. Gracefully terminating.", .{sig});
            },
            std.os.SIG.USR1 => {
                ip.resetProcessing();
                log.info("USR signal {d} received. Reset pipline.", .{sig});
            },
            else => unreachable,
        }
    }
}

/// Produce simple Ready events
const ReadyEvent = enum(u8) {
    NotReady = 0,
    Ready = 1,

    pub fn print(self: @This(), f: util.OuputFormat, writer: anytype) !void {
        const bready: bool = (self == .Ready);
        switch (f) {
            .json => try writer.print("{{\"event\":\"status\",\"ready\":{}}}\n", .{bready}),
            .human => try if (bready) writer.writeAll("Wakeword pipeline is ready\n") else writer.writeAll("Wakeword pipeline is **not** ready\n"),
            .machine => try writer.print("R:{}\n", .{@intFromEnum(self)}),
        }
    }
};
