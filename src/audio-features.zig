//! This module is a stream line version for computing
//! audio features used in openwakeword model
//!
//! The features are computed as follows:
//! Input: signed 16bit 16Khz PCM raw audio samples.
//!
//! [input samples in multiples of 1280(80ms) with 160*3(30ms) overlap with previous frame] this buffer is rolled with frame_size
//!                                    |
//!                                    | melspectogram model = outputs ( N * 32 ) N is variable depending on the length tyically 8 per 1280 chunk
//!                                    V
//! [mel spec buffer matrix with vectors of 32 CEPs
//!
//! 1. Compute mel spectrogram
/// The computation is made by the melspectrogram.tflite model.
/// The model is initialized as:
///     - Interpreter(model_path=melspec_model_path)
///     - resize_tensor_input(0, [1, frame_size]): Input is matrix of one row with a multiple of 1280 samples (80ms of audio)
///     - allocate_tensors
///
///
/// Notes:
/// _streaming_features(x) : Entry point x= i16 variable len audio.
///     1. Acumulate chunks of 80ms (1280 samples) with saving partial content to concatenate.
const std = @import("std");
const rb = @import("rollbuffer.zig");
const mr = @import("model-runner.zig");
const util = @import("util.zig");

// Global parameters (comptime)
// -----------------
/// audio sample rate
pub const SR: usize = 16000;
//  Size of the audio chunk this 80ms required by the mel model that can be processes in multiples for less cpu usage.
pub const chunk_size: usize = 1280;
//  Number of chuncks in a frame
pub const frame_chunks: usize = 4;
/// Frame sizse
pub const frame_size: usize = chunk_size * frame_chunks;
/// overlap
pub const overlap_size: usize = (30 * SR) / 1000; // overlap us

// Model dependent constants
/// number of mel CEPS per model
pub const n_mels: usize = 32;
/// nmber of mel vector needed to produce features
pub const n_mel_to_features: usize = 76;
/// number of features per embeddeing model
pub const n_embeddings: usize = 96;
/// cpus for model run
pub const n_ncpus: i32 = 1;

/// Max error allowed before aboring
const max_error_allowed = 10;

const ll = std.log.scoped(.AudioFeatures);

pub const AudioFeaturesStats = struct {
    audio_frames: u64 = 0,
    mels: u64 = 0,
    features: u64 = 0,
    err_count: u32 = 0,
};

pub const FeaturesType = rb.RollBufferTS([n_embeddings]f32);

pub const AudioFeatures = struct {
    alloc: std.mem.Allocator,
    m_spec: mr.TFRunner,
    m_embe: mr.TFRunner,
    in_rb: rb.RollBufferTS(i16),
    out_rb: *rb.RollBufferTS([n_embeddings]f32), // embeddings model outputs a vector of 96 features
    mel_rb: rb.RollBuffer([n_mels]f32), // internal buffer for storing the mel spectrogram
    mel_rb_roll: usize,
    audio: []f32,
    audio_ready: bool = false,
    running: bool = false,
    active: bool = true,
    stats: AudioFeaturesStats = .{},

    const Self = @This();

    /// Prefills with ones the mels rollbuffer for initilization or reset.
    /// This function resets the buffer and fill
    fn reset_mels(_rb: *rb.RollBuffer([n_mels]f32), roll_size: usize) void {
        const ones = [_]f32{1.0} ** n_mels;
        _rb.reset();
        for (0..n_mel_to_features - roll_size) |_| _ = _rb.append(&([1][n_mels]f32{ones}));
    }

    /// Warms up the input buffer.
    /// The streamer allways process a frame + overlap. On start or on reset the input audio buffer is empty.
    /// so its necessy to pad the begining with some data. in this case with zeros.
    fn warm_up(_in_rb: *rb.RollBufferTS(i16)) void {
        var lrb = _in_rb.lock();
        defer lrb.releaseAndSignal(); // This cleans internal status of the buffer

        lrb.reset();
        const zeros = [_]i16{0} ** overlap_size;
        _ = lrb.append(&zeros);
    }
    /// Init Audifeatures preparing the models and necesary buffers.
    /// Requires a pointer to a rollbuffer for the ouput to produce features.
    /// Inits the input buffer of a propper size that can be accesed via getAudioBuffer()
    pub fn init(alloc: std.mem.Allocator, melspec_model_path: [:0]const u8, embedding_model_path: [:0]const u8, out_rb: *FeaturesType) !Self {

        // Init the mel model. First with the chuck size to get the number of mel vectors of a chunk that will be roll value of the mel
        var m_spec_ = try mr.initRunner(alloc, melspec_model_path, n_ncpus, false, &[_]i32{ 1, overlap_size + chunk_size });
        errdefer m_spec_.deinit();
        const mel_rb_roll_: usize = @intCast(m_spec_.outputShape()[2]); // Get the N mel banks per chunk. should be 8.
        try m_spec_.setInputShape(&[_]i32{ 1, frame_size + overlap_size });

        // Init the embeddings
        const ncpus = if ((std.Thread.getCpuCount() catch 1) > 2) 2 else n_ncpus; // For quadcore+ core allocate 2 threads for this model
        var m_embe_ = try mr.initRunner(alloc, embedding_model_path, ncpus, true, null);
        errdefer m_embe_.deinit();

        // Interal frame buffer as floats
        var audio_ = try alloc.alloc(f32, overlap_size + frame_size);
        errdefer alloc.free(audio_);

        // Internal mel rollbuffer
        const input_mel_banks: usize = @intCast(m_spec_.outputShape()[2]);
        var mel_rb_ = try rb.RollBuffer([n_mels]f32).init(alloc, n_mel_to_features - mel_rb_roll_ + input_mel_banks); // 76 ones - first 8 rolled + 32 of the mels of a frame.
        errdefer mel_rb_.deinit();
        reset_mels(&mel_rb_, mel_rb_roll_); // Prefill

        // Init Audio rollbuffer
        var in_rb_ = try rb.RollBufferTS(i16).init(alloc, frame_size + overlap_size + chunk_size, false); // Capacity is one frame + extra chunk + overlap
        errdefer in_rb_.deinit();
        warm_up(&in_rb_); // allways warns up the input buffer.

        ll.info("Audio features initialized", .{});
        ll.info("Buffer sizes audio={d},mel={d},in={d}", .{ audio_.len, @sizeOf([n_mels]f32) * mel_rb_.capacity(), @sizeOf(i16) * in_rb_.capacity() });
        ll.info("Mel buffer usage={d}/{d} mel roll window={d}", .{ mel_rb_.len(), mel_rb_.capacity(), mel_rb_roll_ });
        ll.debug("Melspectrogram model details:", .{});
        m_spec_.details();
        ll.debug("Word embeddings model details:", .{});
        m_embe_.details();

        return Self{
            .alloc = alloc,
            .m_spec = m_spec_,
            .m_embe = m_embe_,
            .in_rb = in_rb_,
            .out_rb = out_rb,
            .mel_rb = mel_rb_,
            .mel_rb_roll = mel_rb_roll_,
            .audio = audio_,
        };
    }

    /// Destroys audio features processor.
    /// This includes the Audio buffer.
    pub fn deinit(self: *Self) void {
        self.alloc.free(self.audio);
        self.in_rb.deinit();
        self.m_spec.deinit();
        self.mel_rb.deinit();
        self.m_embe.deinit();
    }
    /// gets the audio buffer.
    pub inline fn getAudioBuffer(self: *Self) *rb.RollBufferTS(i16) {
        return &self.in_rb;
    }
    /// Perform benchmarks of the models with fixed data. Returns the average total time.
    pub fn bench(self: *Self, n: usize) !f32 {
        const d: f32 = @floatFromInt(n);
        var totalfeat: u64 = 0;
        var totalmels: u64 = 0;
        var ni = n;
        const outw = std.io.getStdOut().writer();
        outw.print("Start audiofeatures bench for {d} rounds\n", .{n}) catch unreachable;
        while (ni > 0) : (ni -= 1) {
            util.fillRandomAudioF(self.audio);
            var timer = try std.time.Timer.start();
            self.audio_ready = true;
            _ = try self.to_mels();
            const mel_time = timer.lap();
            _ = try self.to_features();
            const feat_time = timer.read();
            totalfeat += feat_time / std.time.ns_per_ms;
            totalmels += mel_time / std.time.ns_per_ms;
            std.debug.print(".{d}.", .{ni});
        }
        const mel_avg: f32 = @as(f32, @floatFromInt(totalmels)) / d;
        const feat_avg: f32 = @as(f32, @floatFromInt(totalfeat)) / d;
        const total_avg = mel_avg + feat_avg;
        outw.print("\nAudio Features bench result mels={d:.2}ms,features={d:.2}ms,total={d:.2}ms\n", .{ mel_avg, feat_avg, total_avg }) catch unreachable;
        return total_avg;
    }
    /// wait for audio and prepare the internal audio return if the buffer is cancelled.
    /// Note: if called in single thread constext the caller must assure that the rollbuffer have sufficient data (to_process)
    //// or the call will block.
    pub fn process_input(self: *Self) rb.RollBufferStatus {
        const to_process = frame_size + overlap_size; // Always process a full frame + overlap with the previous frame
        var lrb = self.in_rb.waitAtLeast(to_process);
        const status = lrb.status(); // Copyout the status

        self.audio_ready = lrb.len() >= to_process; // mark audio ready to indicate there complete samples ready if we have sufficient samples
        if (self.audio_ready) {
            for (lrb.get()[0..to_process], 0..) |e, i| self.audio[i] = @floatFromInt(e); // Convert audio to float
            lrb.roll(frame_size);
            self.stats.audio_frames +%= 1;
        }
        lrb.release();
        return status;
    }

    /// compute & scale the mel coeffients an put them in the mel buffer
    pub fn to_mels(self: *Self) !usize {
        var added: usize = 0;
        if (self.audio_ready) {
            var mels = try self.m_spec.run(std.mem.sliceAsBytes(self.audio), [n_mels]f32); // get the ouput of the model N*32 matrix
            // Scale mels with some hackery pointer cast to iterate over all elements in one loop.
            for (mels) |*melv| {
                for (melv) |*mel|
                    mel.* = @mulAdd(f32, mel.*, 0.1, 2); // mel = mel/10 + 2
            }
            // append to mel buffer
            added = self.mel_rb.append(mels);
            self.audio_ready = false; // Current audio was processed.
        }
        return added;
    }

    /// compute features and put them in the features buffer
    pub fn to_features(self: *Self) !usize {
        var added: usize = 0;
        var out_rb = self.out_rb.lock(); // Locked out buffer
        while (self.mel_rb.len() >= n_mel_to_features) {
            //ll.info("mel comp size={d}", .{self.mel_rb.len()});
            var emb = try self.m_embe.run(std.mem.sliceAsBytes(self.mel_rb.get()[0..n_mel_to_features]), [n_embeddings]f32);
            self.mel_rb.roll(self.mel_rb_roll);
            added += out_rb.append(emb);
        }
        if (added > 0) out_rb.releaseAndSignal() else out_rb.release();
        return added;
    }

    pub fn start(self: *Self) !std.Thread {
        if (self.running) return std.Thread.SpawnError.ThreadQuotaExceeded;
        return std.Thread.spawn(std.Thread.SpawnConfig{}, Self.run, .{self});
    }

    /// Private thread function
    fn run(self: *Self) void {
        self.running = true;
        defer self.running = false;
        var keep_running: bool = true;
        self.stats = AudioFeaturesStats{};

        var input_status: rb.RollBufferStatus = undefined;

        ll.info("Audio features thread started", .{});

        while (keep_running) {

            // 1st process the input samples.
            input_status = self.process_input();
            // 2nd transform audio to mels
            if (self.to_mels()) |added| {
                self.stats.mels +%= added;
            } else |err| {
                self.stats.err_count += 1;
                ll.err("[{d}] Failed to get mels from the model=>{any}", .{ self.stats.err_count, err });
            }
            // 3rd transform mels to features
            if (self.to_features()) |added| {
                self.stats.features +%= added;
            } else |err| {
                self.stats.err_count += 1;
                ll.err("[{d}] Failed to get features from the model=>{any}", .{ self.stats.err_count, err });
            }

            // Check if error count have been reached.
            if (self.stats.err_count > max_error_allowed) {
                ll.err("[{d}] Max error allowed reached. Aborting the thread", .{self.stats.err_count});
                break;
            }

            // Exit & Reset condition
            if (input_status.isFlagged()) {
                keep_running = !input_status.cancel; // if the the buffer is cancelled we stop running.
                if (input_status.reset) { // The audio bufer was reseted we restore internal status
                    self.audio_ready = false;
                    reset_mels(&self.mel_rb, self.mel_rb_roll);
                    warm_up(&self.in_rb);
                    self.out_rb.reset(); // Propagate the reset
                }
            }
        }
        // Cancel the output buffer to propagate the cancellation.
        self.out_rb.cancel();
        ll.info("Audio features thread finished last input status={any},stats={any}", .{ input_status, self.stats });
    }
};
