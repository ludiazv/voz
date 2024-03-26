//! Simple audio processor with webrtc noise gain library
//! This module implements a simple audio processor that process audio in small chunks of signed 16bit PCM mono audiro.
//! The chunck size allowed ar 10,20,30,40,50,60,70 & 80 ms.
//!
//! Internally the preprocessor process audio in sub-chunks of 10ms once at a time.The result of audio processing is
//! the concatenation of the processed sub-chunks.
//!
//! The preprocessor has the following parameters:
//!  - preamp: fixed multiple (float) applied to all audio samples before processing.
//!  - noise reduction level: 0..4 strength applied to the (0= disabled -> 4=max)
//!  - autogain: apply auto gain
//!  - vad: true/false Enable simple
//!
//! The preprocessor has to modes of operation: single threaded or threaded.
//!
//! For single theraded operation:
//!     1.
const std = @import("std");
const os = std.os;
pub const wav = @import("wav.zig");
const rollbuffer = @import("rollbuffer.zig");
pub const webrtc = @cImport({
    @cInclude("webrtc_noise_gain_c.h");
});
const util = @import("util.zig");

pub const InputType = enum { raw, wav };

pub const SR = 16000;
pub const SAMPLES_10MS = SR / 100;
pub const SAMPLES_40MS = SAMPLES_10MS * 4;

const ll = std.log.scoped(.InputProcessor);

pub const InputProcessor = struct {
    alloc: std.mem.Allocator,
    run: std.atomic.Atomic(bool),
    reset: std.atomic.Atomic(bool),
    audio_buffer: []i16,
    out_rb: *rollbuffer.RollBufferTS(i16),
    preprocessor: webrtc.AudioProcessor_t = null,
    pre_multiple: usize,

    const Self = @This();

    /// Init InputProcesseor that reads audio form the inpunt and preprocess the audio
    /// Requires out: the rollbuffer to write and singnal.
    /// chunk size: Size in smaples
    /// ns_level: 0..4 noise reduction strength. 0= disbaled. 4=Max
    /// auto_gain: 0..31 . 0=disabled
    /// preamp: float multiplier to the inmput signal.
    pub fn init(alloc: std.mem.Allocator, out: *rollbuffer.RollBufferTS(i16), chunk_size: usize, ns_level: u8, auto_gain: u8, preamp: f32, vad: bool) !Self {
        std.debug.assert(chunk_size % SAMPLES_10MS == 0); // chunk_size must be a multiple of 10MS
        std.debug.assert(chunk_size >= SAMPLES_10MS); // chuck size >= 10 ms
        const pre_mul = chunk_size / SAMPLES_10MS; // precompute the number of sub-chucks in the chunk_size
        std.debug.assert(pre_mul <= 8); // Max chunk size is 80ms

        var audio = try alloc.alloc(i16, chunk_size);
        errdefer alloc.free(audio);

        const pre = Self.createPreprocessor(ns_level, auto_gain, preamp, vad); // Create the internal processor.

        ll.info("Created input processor audio buffer size={d}, has preprocessor={any}", .{ audio.len * @sizeOf(i16), pre != null });
        return Self{
            .alloc = alloc,
            .out_rb = out,
            .audio_buffer = audio,
            .preprocessor = pre,
            .run = std.atomic.Atomic(bool).init(false),
            .reset = std.atomic.Atomic(bool).init(false),
            .pre_multiple = pre_mul,
        };
    }

    // Create web rtc preprocessor.
    pub fn createPreprocessor(ns_level: u8, auto_gain: u8, preamp: f32, vad: bool) webrtc.AudioProcessor_t {
        return if (ns_level > 0 or preamp != 1 or auto_gain > 0 or vad) blk: { // Any Audio preprocessing is requested.
            const ns = @min(ns_level, 4); // noise clampled at 4
            const ag = @min(auto_gain, 31); // autogain clampled at 31
            const vd: c_int = if (vad) 1 else 0;
            ll.info("Creating audio preprocessor [preamp={d:.4},noise reuduction level={d}, auto gain={d}, vad={d}]", .{ preamp, ns, ag, vd });
            break :blk webrtc.AudioProcessorCreate(ag, ns, preamp, vd);
        } else null;
    }

    /// Destroys web rtc prerprocesor
    pub inline fn destroyPreprocessor(pre: webrtc.AudioProcessor_t) void {
        webrtc.AudioProcessorDelete(pre);
    }
    /// Release object resources.
    pub fn deinit(self: *Self) void {
        self.alloc.free(self.audio_buffer);
        if (self.preprocessor) |pre| Self.destroyPreprocessor(pre);
    }

    /// Signal running thread to stop. This will termitante the thread.
    pub inline fn stop(self: *Self) void {
        self.run.store(false, .Monotonic);
    }

    // Reset the output
    pub inline fn resetProcessing(self: *Self) void {
        self.reset.store(true, .Monotonic);
    }

    /// Starts input thread
    pub fn start(self: *Self, typ: InputType, sdin: std.fs.File, sync: bool) !std.Thread {
        if (self.run.load(.Monotonic)) return std.Thread.SpawnError.ThreadQuotaExceeded;

        return std.Thread.spawn(std.Thread.SpawnConfig{}, Self.processInput, .{ self, typ, sdin, sync });
    }

    pub fn bench(self: *Self, n: usize, runs_per_frame: u64) !f32 {
        const outw = std.io.getStdOut().writer();
        outw.print("Start input processor bench for {d} rounds\n", .{n}) catch unreachable;
        const overhead: f32 = 0.5; // account 0.5ms for active io to collect chuck data.
        const pre = if (self.preprocessor) |pr| pr else {
            outw.print("No input preprocessor defined, using constant time stimation of {d}ms\n", .{overhead}) catch unreachable;
            return overhead; // If no preprocessor bench is constant stimation.
        };
        const d: f32 = @floatFromInt(n);
        var total: u64 = 0;
        var ni = n;
        while (ni > 0) : (ni -= 1) {
            util.fillRandomAudio(self.audio_buffer);
            var timer = try std.time.Timer.start();
            _ = preporcessAudio(pre, self.audio_buffer, self.pre_multiple);
            const pre_time = timer.read() * runs_per_frame;
            //std.debug.print("pt={d}", .{pre_time});
            total += pre_time / std.time.ns_per_ms;
            //std.debug.print(".{d}.", .{ni});
        }

        const tot_avg: f32 = @as(f32, @floatFromInt(total)) / d;
        outw.print("\nInput processor total={d:.2}ms\n", .{tot_avg + overhead}) catch unreachable;
        return tot_avg + overhead;
    }

    /// Preprocess audio bufer in mini chucks of 10ms
    /// Input buffer will be overwriten with the processes samples
    pub fn preporcessAudio(pre: *anyopaque, buf: []i16, n: usize) u8 {
        //var mini_buf: [SAMPLES_10MS]i16 = undefined; // mini buffer of 10ms for preprocesor output (in stack)
        var res: u8 = 0;

        for (0..n) |i| {
            res = res << 1;
            const start_ = i * SAMPLES_10MS;
            const end_ = start_ + SAMPLES_10MS;
            var sub_buf = buf[start_..end_];
            //_ = webrtc.AudioProcessorProcess10ms(pre, sub_buf.ptr, &mini_buf);
            const vad = webrtc.AudioProcessorProcess10ms(pre, sub_buf.ptr, sub_buf.ptr);
            res = res | @as(u8, @intCast(vad));
            //@memcpy(sub_buf, &mini_buf);
        }
        return res;
    }

    fn processInput(self: *Self, typ: InputType, sdin: std.fs.File, sync: bool) void {

        // Defer actitions to perform at thread exit
        defer self.out_rb.cancel(); // cancel the rollbufer signaling no more samples will be provided.
        defer self.run.store(false, .Monotonic); // Unflag the running thread

        self.run.store(true, .Monotonic); // The thread started set thread state as runing
        const source = sdin; //std.io.getStdIn();

        // check wav compatibility
        // -----
        if (typ == .wav) {
            var w = wav.wavReader.init(source) catch |err| {
                ll.err("could not read wav header => {}", .{err});
                return;
            };
            if (w.isCompatible()) {
                w.details();
                ll.info("wav will read {d} chucks\n", .{w.nSamples() / self.audio_buffer.len});
            } else {
                ll.err("wav format incorrect or not compatible. WAV must be 16Khz PCM signed 16-bit mono", .{});
                return;
            }
        }

        // Prepare control variables and constants for the main loop
        // ---
        var pfd = [_]os.pollfd{os.pollfd{ .fd = source.handle, .events = os.POLL.IN, .revents = undefined }}; // poll structure on input.
        const timeout: i32 = @intCast((self.audio_buffer.len * 1000) / SR); // ms in a chunk. Used for timeout on poll read
        const chunk_time_ns: u64 = (@as(u64, @intCast(timeout)) * std.time.ns_per_ms); // chunck time in ns. Used for compute sync wait time
        var audio_as_bytes = std.mem.sliceAsBytes(self.audio_buffer); // audio buffer as byte buffer
        const chunk_bytes = self.audio_buffer.len * @sizeOf(i16); // audio buffer size in bytes

        var total_chunks: usize = 0; // simple stat counter
        var ravg_wait: u64 = 0; // rolling average of wait time in sync mode

        ll.info("Audio Processor thread started for {d} bytes chucks.", .{chunk_bytes});
        defer ll.info("Audio reader thread finished total chunks={d}, r avg wait time={d}ms.", .{ total_chunks, ravg_wait / 1000000 });

        var timer = std.time.Timer.start() catch unreachable; // Start the timer used for sync mode

        // Thread loop
        while (self.run.load(.Monotonic)) {
            var readed_bytes: usize = 0;
            // inner loop to fill the audio buffer
            while (self.run.load(.Monotonic) and !self.reset.load(.Monotonic) and readed_bytes < chunk_bytes) {
                if (std.os.poll(&pfd, timeout)) |n_fds| {
                    if (n_fds == 0) continue; // If timeout continue polling
                    var n = os.read(source.handle, audio_as_bytes[readed_bytes..]) catch |err| {
                        ll.err("I/O error reading audio=>{any}", .{err});
                        return; //aborting reads
                    };
                    if (n == 0) return; // EOF Reached
                    if (n > 0) readed_bytes += n;
                } else |err| {
                    ll.err("Polling error capturing audio=>{any}", .{err});
                    return; // aborting reads
                }
            } // Fill the audio buffer to chuck_size

            // At this point the audiobuffer is full or the thread was cancelled or reseted
            if (self.reset.load(.Monotonic)) {
                self.out_rb.reset();
                self.reset.store(false, .Monotonic); // clear flag
                continue;
            }

            // Check data can be pushed.
            if (readed_bytes == chunk_bytes) {
                total_chunks +%= 1;
                if (self.preprocessor) |pre| _ = Self.preporcessAudio(pre, self.audio_buffer, self.pre_multiple);
                if (self.out_rb.append(self.audio_buffer) != self.audio_buffer.len) ll.warn("Audio chunk not fully added.Rollbuffer overun detected.", .{});
                if (sync) {
                    const wait = chunk_time_ns -| (timer.read() + 1000);
                    if (wait > 0) {
                        os.nanosleep(0, wait);
                        ravg_wait = (wait + ravg_wait) / 2;
                        _ = timer.lap();
                    }
                }
            }
        } // Thread loop

    } // Thread End

};
