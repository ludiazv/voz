//! This is simple wrapper of TFLITE C API with as subset of the api to run
//! inference models in zig. This work is an adaptation of this repository [https://github.com/mattn/zig-tflite] that
//! is not compatible with recent versions of zig
//! Note: This is a low level wrapper that does not control all error situations please use with care.
//! This core requiure libc linking.

const c = @cImport({
    @cInclude("tensorflow/lite/c/c_api.h");
    @cInclude("tensorflow/lite/delegates/xnnpack/xnnpack_delegate.h");
});

const std = @import("std");

/// Get TF LITE version
pub fn version() [*c]const u8 {
    return c.TfLiteVersion();
}

/// TFLITE model wrapper
pub const Model = struct {
    m: *c.TfLiteModel,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        c.TfLiteModelDelete(self.m);
    }
};
/// Load a model from file
pub fn modelFromFile(path: [:0]const u8) !Model {
    var m = c.TfLiteModelCreateFromFile(@ptrCast(path));
    if (m == null) {
        return error.AllocationError;
    }
    return Model{ .m = m.? };
}

/// TFLITE intrepreter options wrapper
pub const InterpreterOptions = struct {
    o: *c.TfLiteInterpreterOptions,
    xnn_delegate: ?*c.TfLiteDelegate = null,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        c.TfLiteInterpreterOptionsDelete(self.o);
    }

    pub fn setNumThreads(self: *Self, num_threads: i32) void {
        c.TfLiteInterpreterOptionsSetNumThreads(self.o, num_threads);
    }

    pub fn addDelegate(self: *Self, d: anytype) void {
        c.TfLiteInterpreterOptionsAddDelegate(self.o, @ptrCast(d));
    }

    pub fn addXNNPack(self: *Self, num_threads: i32) !void {
        var xnnp_opt = c.TfLiteXNNPackDelegateOptionsDefault();
        xnnp_opt.num_threads = @max(1, num_threads);
        //xnnp_opt.flags |= 0x00000004;
        self.xnn_delegate = c.TfLiteXNNPackDelegateCreate(&xnnp_opt);
        if (self.xnn_delegate == null) return error.AllocateError;
        self.addDelegate(self.xnn_delegate);
    }
};

/// Create the options
pub fn interpreterOptions() !InterpreterOptions {
    var o = c.TfLiteInterpreterOptionsCreate();
    if (o == null) {
        return error.AllocationError;
    }
    return InterpreterOptions{ .o = o.? };
}

pub fn XNNPackDelegateOptionsDefault() c.TfLiteXNNPackDelegateOptions {
    return c.TfLiteXNNPackDelegateOptionsDefault();
}

/// TF LITE interpreter wrapper
pub const Interpreter = struct {
    i: *c.TfLiteInterpreter,

    const Self = @This();

    pub fn deinit(self: *Self) void {
        c.TfLiteInterpreterDelete(self.i);
    }

    pub fn allocateTensors(self: *Self) !void {
        if (c.TfLiteInterpreterAllocateTensors(self.i) != 0) {
            return error.AllocationError;
        }
    }

    pub fn invoke(self: *Self) !void {
        if (c.TfLiteInterpreterInvoke(self.i) != 0) {
            return error.RuntimeError;
        }
    }

    pub fn inputTensorCount(self: *const Self) i32 {
        return c.TfLiteInterpreterGetInputTensorCount(self.i);
    }

    pub fn inputTensorIndices(self: *const Self) ?[]const i32 {
        const count = c.TfLiteInterpreterGetInputTensorCount(self.i);
        if (count == 0) return null;
        const items = c.TfLiteInterpreterInputTensorIndices(self.i);
        return items[0..@intCast(count)];
    }

    pub fn inputTensor(self: *Self, index: i32) Tensor {
        return Tensor{
            .t = c.TfLiteInterpreterGetInputTensor(self.i, index).?,
        };
    }

    pub fn outputTensorCount(self: *const Self) i32 {
        return c.TfLiteInterpreterGetOutputTensorCount(self.i);
    }

    pub fn outputTensorIndices(self: *const Self) ?[]const i32 {
        const count = c.TfLiteInterpreterGetOutputTensorCount(self.i);
        if (count == 0) return null;
        const items = c.TfLiteInterpreterOutputTensorIndices(self.i);
        return items[0..@intCast(count)];
    }
    pub fn outputTensor(self: *Self, index: i32) Tensor {
        return Tensor{
            .t = c.TfLiteInterpreterGetOutputTensor(self.i, index).?,
        };
    }

    pub fn getTensor(self: *const Self, index: i32) Tensor {
        return Tensor{ .t = c.TfLiteInterpreterGetTensor(self.i, index).? };
    }
    pub fn resizeInput(self: *Self, index: i32, dims: []const i32) !void {
        if (c.TfLiteInterpreterResizeInputTensor(self.i, index, dims.ptr, @intCast(dims.len)) != 0) return error.RuntimeError;
    }
};

pub fn interpreter(model: Model, options: InterpreterOptions) !Interpreter {
    var i = c.TfLiteInterpreterCreate(model.m, options.o);
    if (i == null) {
        return error.AllocationError;
    }
    return Interpreter{ .i = i.? };
}

pub const Tensor = struct {
    t: *c.TfLiteTensor,

    const Self = @This();

    pub fn tensorType(self: *const Self) u32 {
        return c.TfLiteTensorType(self.t);
    }

    pub fn numDims(self: *const Self) i32 {
        return c.TfLiteTensorNumDims(self.t);
    }

    pub fn dim(self: *const Self, index: i32) i32 {
        return c.TfLiteTensorDim(self.t, index);
    }

    pub fn shape(self: *const Self, allocator: std.mem.Allocator) !std.ArrayList(i32) {
        var s = std.ArrayList(i32).init(allocator);
        var i: i32 = 0;
        while (i < self.numDims()) : (i += 1) {
            try s.append(self.dim(i));
        }
        return s;
    }

    pub fn byteSize(self: *const Self) usize {
        return c.TfLiteTensorByteSize(self.t);
    }

    pub fn data(self: *const Self, comptime T: type) []T {
        var d = c.TfLiteTensorData(self.t);
        var a = c.TfLiteTensorByteSize(self.t) / @sizeOf(T);
        var cr: [*]T = @ptrCast(@alignCast(d.?));
        //@alignCast(d.?)[0..a];
        return cr[0..a];
        //return @ptrCast([*]T, @alignCast(@alignOf(T), d.?))[0..a];
    }

    pub fn setData(self: *Self, data_in: []const u8) !void {
        const l = c.TfLiteTensorByteSize(self.t);
        if (l != data_in.len) return error.RuntimeError;
        if (c.TfLiteTensorCopyFromBuffer(self.t, data_in.ptr, data_in.len) != 0) return error.RuntimeError;
    }

    pub fn name(self: *const Self) []const u8 {
        var n = c.TfLiteTensorName(self.t);
        //var len = c.strlen(n);
        const len = std.mem.len(n);
        return n[0..len];
    }
};
