//! This module compute the prediction of wake words models.
//! Iterate over a feature buffer one feature vector per 80ms audio chuck computed
//! in audio-features.zig
const std = @import("std");
const mr = @import("model-runner.zig");
const rollbuffer = @import("rollbuffer.zig");
const audiofeatures = @import("audio-features.zig");
const util = @import("util.zig");

const ll = std.log.scoped(.WakeWord);

//const disabled_sleep_time = std.time.ns_per_ms * 250;

/// wakeword config
pub const WakeWordConfig = struct {
    name: []const u8,
    model_path: [:0]const u8,
    threshold: f32 = 0.5,
    patience: u32 = 1,
    // Internal control variables
    model: mr.TFRunner = undefined,
    window: usize = 16,
    offset: usize = 0,
    patience_counter: u32 = 0,
};
/// Prediction
pub const WakeWordPrediction = struct {
    name: []const u8,
    score: f32,
    count: u32,

    pub fn print(self: *const @This(), f: util.OuputFormat, w: anytype) !void {
        switch (f) {
            .json => try w.print("{{ \"event\":\"prediction\",\"wakeword\":\"{s}\",\"prob\":{d:.4},\"cnt\":{d} }}\n", .{ self.name, self.score, self.count }),
            .human => try w.print("Matched prediction for '{s}' with probability {d:.2} and count {d}\n", .{ self.name, self.score, self.count }),
            .machine => try w.print("P:{s}:{d:.4}:{d}\n", .{ self.name, self.score, self.count }),
        }
    }
};

pub const PredicionType = rollbuffer.RollBufferTS(WakeWordPrediction);
pub const FeaturesType = audiofeatures.FeaturesType;

pub const WakeWord = struct {
    alloc: std.mem.Allocator,
    in_rb: FeaturesType,
    out_rb: *PredicionType,
    ww: []WakeWordConfig,
    max_window: usize,
    min_window: usize,
    running: bool = false,

    const Self = @This();

    pub fn init(alloc: std.mem.Allocator, config: []WakeWordConfig, predictions: *PredicionType) !Self {
        var max_window: usize = 0;
        var min_window: usize = 0;
        // Init internal model and calculate model window
        for (config) |*ww| {
            ww.model = try mr.initRunner(alloc, ww.model_path, 1, true, null);
            errdefer ww.model.deinit();
            ww.window = @intCast(ww.model.inputShape()[1]); // Features need in the model input
            if (ww.window > max_window) max_window = ww.window;
            if (ww.window < min_window) min_window = ww.window;
        }
        // Compute the model offest
        for (config) |*ww| ww.offset = max_window - ww.window;

        // Init the input features buffer
        var in_rb_ = try FeaturesType.init(alloc, max_window + 1, false);
        errdefer in_rb_.deinit();

        for (config) |*ww| {
            std.debug.print("Details for wakework model name={s}\n", .{ww.name});
            ww.model.details();
        }
        return Self{
            .alloc = alloc,
            .in_rb = in_rb_,
            .out_rb = predictions,
            .ww = config,
            .max_window = max_window,
            .min_window = min_window,
            //.disabled = std.atomic.Atomic(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.ww) |*ww| ww.model.deinit();
        self.in_rb.deinit();
    }

    pub inline fn getFeaturesBuffer(self: *Self) *FeaturesType {
        return &self.in_rb;
    }

    pub fn bench(self: *Self, n: usize, runs_per_frame: u64) !f32 {
        const d: f32 = @floatFromInt(n);
        var total: u64 = 0;

        std.debug.print("Start wakeword bench for {d} rounds\n", .{n});

        var feat = try FeaturesType.innerType.init(self.alloc, self.max_window);
        defer feat.deinit();
        while (feat.free() > 0) {
            const dat = [_]f32{0.98} ** audiofeatures.n_embeddings;
            _ = feat.append(&([1][audiofeatures.n_embeddings]f32{dat}));
        }
        var ni = n;
        while (ni > 0) : (ni -= 1) {
            var timer = try std.time.Timer.start();
            _ = self.predict(&feat);
            total += (timer.read() * runs_per_frame) / std.time.ns_per_ms;
            //std.debug.print(".{d}.", .{ni});
        }
        const tot_avg: f32 = @as(f32, @floatFromInt(total)) / d;
        std.debug.print("\nWakeword total={d:.2}ms\n", .{tot_avg});
        return tot_avg;
    }

    pub fn start(self: *Self) !std.Thread {
        if (self.running) return std.Thread.SpawnError.ThreadQuotaExceeded;
        // Todo twack stack size to reduce overhead (by default is 16Mb)
        return std.Thread.spawn(std.Thread.SpawnConfig{}, Self.run, .{self});
    }

    fn evaluate_prediction(ww: *WakeWordConfig, prediction: f32) ?WakeWordPrediction {
        if (prediction <= ww.threshold) {
            // reset patience counter
            ww.patience_counter = 0;
            return null;
        }

        // Detction posivite!
        ww.patience_counter += 1;
        return if (ww.patience_counter >= ww.patience) WakeWordPrediction{ .name = ww.name, .score = prediction, .count = ww.patience_counter } else null;
    }

    fn predict(self: *Self, features: *FeaturesType.innerType) usize {
        const features_len = features.len();
        if (features_len < self.min_window) return 0; // if not mim features avaible this a nop
        // Iterate over the models compute each model predicion
        var added: usize = 0;
        var lrb = self.out_rb.lock();
        for (self.ww) |*ww| {
            if (features_len < ww.window + ww.offset) continue; // dont consider this model as there is not sufficient features.
            const window = std.mem.sliceAsBytes(features.get()[ww.offset .. ww.offset + ww.window]);
            var prediction = ww.model.run(window, [1]f32) catch continue;
            if (Self.evaluate_prediction(ww, prediction[0][0])) |*pre| {
                //added += lrb.append(&([1]WakeWordPrediction{pre}));
                added += lrb.appendOne(pre);
            }
        }
        lrb.releaseAndSignal();
        return added;
    }

    fn run(self: *Self) void {
        var keep_running = true;
        self.running = true;
        defer self.running = false;
        var total: u64 = 0;

        var input_status: rollbuffer.RollBufferStatus = undefined;
        ll.info("Thread for wakeword detection has started for with models:", .{});
        for (self.ww) |ww| ll.info("model={s},threshold={d:.2},patience={d},window={d},window offset={d}", .{ ww.name, ww.threshold, ww.patience, ww.window, ww.offset });

        while (keep_running) {
            var lrb = self.in_rb.waitAtLeast(self.max_window);
            input_status = lrb.status(); // copyout the status
            while (lrb.len() >= self.max_window) {
                total +%= self.predict(lrb.rb);
                lrb.roll(1);
            }
            lrb.release();
            // Exit condition
            keep_running = !input_status.cancel;
        }
        // Exit the running buffer
        self.out_rb.cancel();
        ll.info("Thread for wakeword detection has finished predictions={d}, last status={any}", .{ total, input_status });
    }
};
