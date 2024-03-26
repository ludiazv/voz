//! Simple wraper arround TFLITE models
//!
const std = @import("std");
const tf = @import("tflite.zig");

const ll = std.log.scoped(.TFRunner);

pub const ModelRunnerError = error{
    NotRunnable,
};

/// Runner object - store & proxies relevant TFLITE object.
/// This objecti must be instaciated by initRunner function that allocates and prepare the model to run
/// To run the model run method must be called that will perfom the model inference
///
/// Note: This wrapper is limited to one input tensor and one output tensor.
pub const TFRunner = struct {
    alloc: std.mem.Allocator,
    tf_model: tf.Model,
    tf_options: tf.InterpreterOptions,
    tf_interpreter: tf.Interpreter,
    input_index: i32,
    output_index: i32,
    input_dims: []i32,
    output_dims: []i32,

    const Self = @This();

    /// Deinit the runner freening memory and deallocationing TFLITE resources
    pub fn deinit(self: *Self) void {
        self.alloc.free(self.input_dims);
        self.alloc.free(self.output_dims);
        self.tf_interpreter.deinit();
        self.tf_options.deinit();
        self.tf_model.deinit();
    }

    /// Run the model feeding to the model the raw data in [din] and returs the output tensor as slice of comptime Tout.
    /// The caller must know the shape of the output data at compile time and feed the model with a valid raw data (as bytes)
    /// compatible with the model. run method does not perform transformation.
    /// Note: Imput data is copied to TF tensor but the output data is points to a memory allocated by tensor flow
    pub fn run(self: *Self, din: []const u8, comptime Tout: type) ![]Tout {
        var t = self.tf_interpreter.getTensor(self.input_index);
        try t.setData(din);
        try self.tf_interpreter.invoke();
        t = self.tf_interpreter.getTensor(self.output_index);
        return t.data(Tout);
    }

    /// change input shape at runtime if the model allow it.
    pub fn setInputShape(self: *Self, is: []const i32) !void {
        try self.tf_interpreter.resizeInput(0, is);
        try self.tf_interpreter.allocateTensors();

        // Re capture input & output shape
        self.alloc.free(self.input_dims);
        var t = self.tf_interpreter.getTensor(self.input_index);
        var i_dim_ = try t.shape(self.alloc);
        self.input_dims = try i_dim_.toOwnedSlice();
        self.alloc.free(self.output_dims);
        t = self.tf_interpreter.getTensor(self.output_index);
        var o_dim_ = try t.shape(self.alloc);
        self.output_dims = try o_dim_.toOwnedSlice();
    }

    /// Get a slice of i32 with the dimensions of the input tensor
    pub fn inputShape(self: *const Self) []const i32 {
        return self.input_dims;
    }

    /// Get a slice of the output shape.
    pub fn outputShape(self: *const Self) []const i32 {
        return self.output_dims;
    }

    /// Log the details of the model
    pub fn details(self: *Self) void {
        ll.debug(">-----------------", .{});
        const i = self.tf_interpreter.getTensor(self.input_index);
        const o = self.tf_interpreter.getTensor(self.output_index);
        //var o_dim_ = try o.shape(self.alloc);
        //const o_dim = try o_dim_.toOwnedSlice();
        //defer self.alloc.free(o_dim);
        ll.debug("  [#{d}] 0->Input tensor index={d},name={s},size={d},type={},dims={any}", .{ self.tf_interpreter.inputTensorCount(), self.input_index, i.name(), i.byteSize(), i.tensorType(), self.input_dims });

        ll.debug("  [#{d}] 0->Output tensor index={d},name={s},size={d},type={},dims={any}", .{ self.tf_interpreter.outputTensorCount(), self.output_index, o.name(), o.byteSize(), o.tensorType(), self.output_dims });
    }
};

/// Init the Runner loading the model
/// alloc: Alloctator for allocationg internal variables.
/// path: a \0 sentinel string with the .tflite path.
/// ncpus: number of cpus(threads) used for inference.
/// xnn: bool use XNNPack
/// input_shape: optional input shape for the model.
pub fn initRunner(alloc: std.mem.Allocator, path: [:0]const u8, ncpus: i32, xnn: bool, input_shape: ?[]const i32) !TFRunner {
    var tfm = try tf.modelFromFile(path);
    errdefer tfm.deinit();
    var tfo = try tf.interpreterOptions();
    errdefer tfo.deinit();
    tfo.setNumThreads(@max(1, ncpus));
    if (xnn) try tfo.addXNNPack(@max(1, ncpus));
    var tfi = try tf.interpreter(tfm, tfo);
    errdefer tfi.deinit();

    // Get input + output indices
    const n_inputs = tfi.inputTensorCount();
    if (n_inputs < 1) return ModelRunnerError.NotRunnable;
    const i_index = tfi.inputTensorIndices().?[0];
    const n_outputs = tfi.outputTensorCount();
    if (n_outputs < 1) return ModelRunnerError.NotRunnable;
    const o_index = tfi.outputTensorIndices().?[0];

    // If required set the input shape & allocate vectors.
    if (input_shape) |is| try tfi.resizeInput(0, is);
    try tfi.allocateTensors();

    // Save input and output shape
    var t = tfi.getTensor(i_index);
    var i_dim_ = try t.shape(alloc);
    const i_dim = try i_dim_.toOwnedSlice();
    errdefer alloc.free(i_dim);
    t = tfi.getTensor(o_index);
    var o_dim_ = try t.shape(alloc);
    const o_dim = try o_dim_.toOwnedSlice();
    errdefer alloc.free(o_dim);

    return TFRunner{
        .alloc = alloc,
        .tf_model = tfm,
        .tf_options = tfo,
        .tf_interpreter = tfi,
        .input_index = i_index,
        .output_index = o_index,
        .input_dims = i_dim,
        .output_dims = o_dim,
    };
}
