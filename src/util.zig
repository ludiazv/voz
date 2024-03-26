const std = @import("std");
const os = std.os;
const path = std.fs.path;

pub const VOZ_VERSION = @embedFile("VERSION.txt");

pub const OuputFormat = enum {
    json,
    machine,
    human,
};

/// global Prng
var prng = std.rand.DefaultPrng.init(0);

pub fn fillRandomAudio(b: []i16) void {
    for (b) |*e| e.* = prng.random().intRangeLessThanBiased(i16, -2000, 2000);
}
pub fn fillRandomAudioF(b: []f32) void {
    for (b) |*e| e.* = @floatFromInt(prng.random().intRangeLessThanBiased(i16, -2000, 2000));
}

pub fn absPathExe(alloc: std.mem.Allocator, dir: ?[]const u8, file: []const u8) ![:0]u8 {
    const exe_path = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(exe_path);
    const opt_exe_dir = std.fs.path.dirname(exe_path) orelse unreachable;

    return if (dir) |d| path.joinZ(alloc, &([_][]const u8{ opt_exe_dir, d, file })) else path.joinZ(alloc, &([_][]const u8{ opt_exe_dir, file }));
}

pub fn customPath(alloc: std.mem.Allocator, dir: []const u8, file: []const u8) ![:0]u8 {
    if (std.fs.path.isAbsolute(dir)) {
        return std.fs.path.joinZ(alloc, &([_][]const u8{ dir, file }));
    } else {
        var cwd: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        const cwd_path = try std.os.getcwd(&cwd);
        return std.fs.path.joinZ(alloc, &([_][]const u8{ cwd_path, dir, file }));
    }
}

pub fn registerSignal(signal: u6, handler: os.Sigaction.handler_fn) !void {
    const act = os.Sigaction{
        .handler = .{ .handler = handler },
        .mask = os.empty_sigset,
        .flags = 0,
    };

    return os.sigaction(signal, &act, null);
}
