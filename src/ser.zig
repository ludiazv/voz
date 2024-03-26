//! zig implementation of serial protocol & State control.
//!
const std = @import("std");
const util = @import("util.zig");
const SAMPLES_40MS = @import("input-processor.zig").SAMPLES_40MS;

const ll = std.log.scoped(.Ser);

// ------- Serial Protocol -------
// -------------------------------

/// Start of header
pub const SOH: u8 = 0x01;
/// max payload size
pub const MAX_PAYLOAD_SIZE = 2048;
/// Event codes
pub const EventId = enum(u8) {
    Nop = 0x00,
    Status = 0x01,
    Mode = 0x10,
    Config = 0x11,
    Audio = 0x12,
    BAudio = 0x13,
    Areset = 0x14,
    Reboot = 0x15,
    WwList = 0x20,
    WwStatus = 0x21,
    WwConf = 0x22,
    WwMatch = 0x23,
    _,
};
/// Supported modes
pub const ModeId = enum(u8) {
    Idle = 0x00,
    WakeWord = 0x01,
    Preprocessor = 0x02,
    _,

    pub inline fn asU8(self: @This()) u8 {
        return @as(u8, @intFromEnum(self));
    }
};
/// Custom errors
pub const VozSerialError = error{
    NoSOH,
    HeaderIntegrity,
    PayloadTooBig,
    InvalidPayloadLen,
    PayloadChecksum,
    UnknownEvent,
    IncompleteEvent,
};

/// Serial Header
pub const Header = extern struct {
    event_id: EventId align(1) = .Nop,
    event_id_comp: u8 align(1) = 0xFF,
    event_extra: u8 align(1) = 0,
    payload_size: u16 align(1) = 0,

    const Self = @This();

    /// Reads a header from a reader (serial port)
    /// has_sok: read Try to read the SOH
    pub fn fromReader(reader: anytype, has_soh: bool) !Self {
        if (has_soh) {
            const soh = try reader.readByte(); // Read SOH if needed
            if (soh != SOH) return VozSerialError.NoSOH;
        }
        var h = try reader.readStruct(Self);
        // Check Header integrity
        if (@intFromEnum(h.event_id) != ~h.event_id_comp) return error.HeaderIntegrity;
        // Check checksum
        const chk = try reader.readByte();
        if (chk != calcChecksum(&h)) return error.HeaderIntegrity;

        if (h.payload_size > MAX_PAYLOAD_SIZE) return error.PayloadTooBig;

        return h;
    }

    /// Write header to a writer (buffer writer is recommended)
    pub fn write(self: *const Self, writer: anytype, write_soh: bool) !usize {
        var n: usize = 0;
        if (write_soh) {
            try writer.writeByte(SOH);
            n += 1;
        }
        try writer.writeStruct(self.*);
        n += @sizeOf(Self);
        try writer.writeByte(calcChecksum(self));
        return n + 1;
    }
    /// Instanciate an Header from its components
    pub fn init(id: EventId, extra: ?u8, payload_size: ?u16) Self {
        return Self{
            .event_id = id,
            .event_id_comp = ~@intFromEnum(id),
            .event_extra = if (extra) |e| e else 0,
            .payload_size = if (payload_size) |ps| ps else 0,
        };
    }

    // Check correctnes of size and alignment
    comptime {
        std.debug.assert(@sizeOf(Header) == 5);
        std.debug.assert(@offsetOf(Header, "payload_size") == 3);
    }
};

/// utility function to compute checksum of any pointer
fn calcChecksum(ref_: anytype) u8 {
    const tinfo = @typeInfo(@TypeOf(ref_));
    switch (tinfo) {
        .Pointer => |inf| {
            const bytes: []const u8 = if (inf.size == .One) std.mem.asBytes(ref_) else std.mem.sliceAsBytes(ref_);
            // Calc the checksum
            var sum: u32 = 0;
            for (bytes) |b| sum += @as(u32, b);
            return @intCast(sum % 256);
        },
        else => @compileError("Checksum calck only operate on pointers"),
    }
}

/// Audio configuration
pub const AudioConf = extern struct {
    preamp: f32 align(1) = 1.0,
    noiser: u8 align(1) = 0,
    autogain: u8 align(1) = 0,
    vad: u8 align(1) = 0,

    /// Formating Audio conf to command line parameters
    pub fn toCmd(self: *const @This(), alloc: std.mem.Allocator, vad: bool) ![4][:0]const u8 {
        var pars: [4][:0]const u8 = undefined;
        pars[0] = try std.fmt.allocPrintZ(alloc, "--preamp={d:.4}", .{self.preamp});
        pars[1] = try std.fmt.allocPrintZ(alloc, "--noiser={d}", .{self.noiser});
        pars[2] = try std.fmt.allocPrintZ(alloc, "--autogain={d}", .{self.autogain});
        if (vad) pars[3] = try std.fmt.allocPrintZ(alloc, "--vad={d}", .{self.vad});
        return pars;
    }

    comptime {
        std.debug.assert(@sizeOf(AudioConf) == 7);
    }
};
/// Internal Reported status
pub const ReportedStatus = enum(u8) {
    Normal = 0x00,
    ChildIoError = 0x10,
    SerialIoError = 0x20,
    InternalError = 0x30,
};

/// Status
pub const Status = extern struct {
    sta: ReportedStatus align(1) = .Normal,
    mode: ModeId align(1) = .Idle,
    n_wakewords: u8 align(1) = 0,
    wakeword_mask: u16 align(1) = 0,
    audio_conf: AudioConf align(1) = .{},
    refrac: u8 align(1) = 0,
    comptime {
        std.debug.assert(@sizeOf(Status) == 6 + @sizeOf(AudioConf));
    }
};
/// Wakeword Configuration
pub const WwConf = extern struct {
    index: u8 align(1) = 0,
    enabled: u8 align(1) = 0,
    threshold: f32 align(1) = 0.5,
    patience: u8 align(1) = 1,

    comptime {
        std.debug.assert(@sizeOf(WwConf) == 7);
    }
};

/// Wakeword status
pub const WwStatus = extern struct {
    name: [32 + 1]u8 align(1) = undefined,
    conf: WwConf align(1) = .{},

    comptime {
        std.debug.assert(@sizeOf(WwStatus) == 33 + @sizeOf(WwConf));
    }
};
/// WakeWord match
pub const WwMatch = extern struct {
    index: u8 align(1),
    score: f32 align(1),
    count: u8 align(1),

    /// Constructor from <index>:<score>:<count> u8 slice
    pub fn fromSlice(sl: []const u8) !@This() {
        // no heap allocation using a fixed buffer avoid dynamica allocation.
        var buf: [512]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const alloc = fba.allocator();

        // split
        var ele = try std.ArrayList([]const u8).initCapacity(alloc, 3);
        defer ele.deinit();
        var it = std.mem.splitScalar(u8, sl, ':'); // Split iterator
        while (it.next()) |e| try ele.append(e);

        // parse elements
        const itm = ele.items;
        if (itm.len < 3) return std.fmt.ParseIntError.InvalidCharacter;
        return WwMatch{
            .index = try std.fmt.parseInt(u8, itm[0], 10),
            .score = std.fmt.parseFloat(f32, itm[1]) catch 0.5,
            .count = std.fmt.parseInt(u8, itm[2], 10) catch 0,
        };
    }

    // Test size and aligment
    comptime {
        std.debug.assert(@sizeOf(WwMatch) == 2 + 4);
        std.debug.assert(@offsetOf(WwMatch, "count") == 5);
    }
};

/// Protocolo Event definion
pub const Event = union(EventId) {
    Nop: void,
    Status: Status,
    Mode: ModeId,
    Config: AudioConf,
    Audio: []const u8,
    BAudio: struct { u8, []const u8 }, // Tuple vad info + audio
    Areset: u8,
    Reboot: void,
    WwList: bool,
    WwStatus: WwStatus,
    WwConf: WwConf,
    WwMatch: WwMatch,

    const Self = @This();

    /// Read an event from reader
    pub fn readEvent(reader: anytype, wait_soh: bool, audio_buf: []u8) !Self {
        const h = try Header.fromReader(reader, wait_soh);
        return switch (h.event_id) {
            .Nop => .Nop,
            .Status => Self{ .Status = try Self.readPayload(Status, reader, h.payload_size) },
            .Mode => Self{ .Mode = @enumFromInt(h.event_extra) },
            .Config => Self{ .Config = try Self.readPayload(AudioConf, reader, h.payload_size) },
            .Audio => Self{ .Audio = try Self.readAudio(reader, audio_buf, h.payload_size) },
            .BAudio => Self{ .BAudio = .{ h.event_extra, try Self.readAudio(reader, audio_buf, h.payload_size) } },
            .Areset => Self{ .Areset = h.event_extra },
            .Reboot => .Reboot,
            .WwList => Self{ .WwList = (h.event_extra != 0) },
            .WwStatus => Self{ .WwStatus = try Self.readPayload(WwStatus, reader, h.payload_size) },
            .WwConf => Self{ .WwConf = try Self.readPayload(WwConf, reader, h.payload_size) },
            .WwMatch => Self{ .WwMatch = try Self.readPayload(WwMatch, reader, h.payload_size) },
            else => VozSerialError.UnknownEvent,
        };
    }

    /// Read the payload as struct
    fn readPayload(comptime T: type, reader: anytype, len: usize) !T {
        if (@sizeOf(T) != len) return VozSerialError.InvalidPayloadLen;

        var payload: [1]T = undefined;
        const readed = try reader.readAll(std.mem.sliceAsBytes(payload[0..]));
        if (readed != @sizeOf(T)) return VozSerialError.IncompleteEvent;

        const chk = try reader.readByte();
        return if (chk == calcChecksum(&payload[0])) payload[0] else VozSerialError.PayloadChecksum;
    }

    /// Read payload as Audio buffer.
    fn readAudio(reader: anytype, buf: []u8, len: usize) ![]u8 {
        if (buf.len < len) return VozSerialError.InvalidPayloadLen;
        const readed = try reader.readAll(buf[0..len]); // Reads all bytes
        if (readed != len) return VozSerialError.IncompleteEvent;
        const chk = try reader.readByte();
        return if (chk == calcChecksum(buf[0..len])) buf[0..len] else VozSerialError.PayloadChecksum;
    }

    /// Serialize payload from struct
    fn writePayload(writer: anytype, ref_: anytype) !usize {
        const tinfo = @typeInfo(@TypeOf(ref_));
        switch (tinfo) {
            .Pointer => |inf| {
                const chk = calcChecksum(ref_);
                const bytes: []const u8 = if (inf.size == .One) std.mem.asBytes(ref_) else std.mem.sliceAsBytes(ref_);
                try writer.writeAll(bytes);
                try writer.writeByte(chk);
                return bytes.len + 1;
            },
            else => @compileError("writePayload only operate on pointers"),
        }
    }
    /// Write event
    pub fn write(self: *const Self, writer: anytype, send_soh: bool) !usize {
        //ll.info("SE:{}", .{self.*});
        const h = switch (self.*) {
            .Nop => Header.init(.Nop, null, null),
            .Status => Header.init(.Status, null, @sizeOf(Status)),
            .Mode => |m| Header.init(.Mode, m.asU8(), null),
            .Config => Header.init(.Config, null, @sizeOf(AudioConf)),
            .Audio => |a| Header.init(.Audio, null, @as(u16, @intCast(a.len))),
            .Areset => |e| Header.init(.Areset, e, null),
            .Reboot => Header.init(.Reboot, null, null),
            .WwList => |m| Header.init(.WwList, if (m) 1 else 0, null),
            .WwStatus => |c| Header.init(.WwStatus, c.conf.index, @sizeOf(WwStatus)),
            .WwMatch => |m| Header.init(.WwMatch, m.index, @sizeOf(WwMatch)),
            else => return VozSerialError.UnknownEvent,
        };

        var n = try h.write(writer, send_soh); // Write header
        n += switch (self.*) {
            .Status => |*st| try Self.writePayload(writer, st),
            .Config => |*cf| try Self.writePayload(writer, cf),
            .Audio => |au| try Self.writePayload(writer, au),
            .WwStatus => |*cf| try Self.writePayload(writer, cf),
            .WwMatch => |*m| try Self.writePayload(writer, m),
            else => 0,
        };

        return n;
    }
};

// --------- Wake word management -----------
// ------------------------------------------
/// Wakeword Entry
pub const WwInfo = struct {
    path: []const u8,
    status: WwStatus,

    /// Init info.
    /// path is duplicated.
    pub fn init(alloc: std.mem.Allocator, path: []const u8, index: u8) !@This() {
        return WwInfo{
            .path = try alloc.dupe(u8, path),
            .status = .{ .conf = .{ .index = index } },
        };
    }

    /// Free memory
    pub fn deinit(self: *@This(), alloc: std.mem.Allocator) void {
        alloc.free(self.path);
    }
    /// Format wakeword in cmd argument format.
    /// The caller must deallocate memory reserved.
    pub fn toCmd(self: *const @This(), alloc: std.mem.Allocator) !?[:0]const u8 {
        return if (self.status.conf.enabled == 0) null else try std.fmt.allocPrintZ(alloc, "{s}:{d}:{d:.2}:{d}", .{ self.path, self.status.conf.index, self.status.conf.threshold, self.status.conf.patience });
    }
    pub fn details(self: *const @This()) void {
        ll.info("WWINFO: path={s} [idx={d} name={s} enabled={d} th={d} patience={d}]", .{ self.path, self.status.conf.index, self.status.name, self.status.conf.enabled, self.status.conf.threshold, self.status.conf.patience });
    }
};

/// Wakewords List
pub const WwList = struct {
    list: std.ArrayList(WwInfo),
    alloc: std.mem.Allocator,
    mask: u16,

    const Self = @This();
    pub fn load(alloc: std.mem.Allocator, base_dir: []const u8) !Self {
        var list = try loadWakewords(alloc, base_dir, @bitSizeOf(u16));
        if (list.items.len > 0) list.items[0].status.conf.enabled = 1; // Mark first enabled as default.
        return Self{
            .list = list,
            .alloc = alloc,
            .mask = if (list.items.len > 0) 1 else 0,
        };
    }

    pub fn updateMask(self: *Self) u16 {
        var new_mask: u16 = 0;
        for (self.list.items) |e| {
            if (e.status.conf.enabled != 0) new_mask |= std.math.shl(u16, 1, e.status.conf.index);
        }
        self.mask = new_mask;
        return new_mask;
    }

    pub inline fn item(self: *const Self, n: usize) ?*WwInfo {
        return if (self.len() > 0 and n < self.len()) &self.list.items[n] else null;
    }

    pub inline fn len(self: *const Self) usize {
        return self.list.items.len;
    }

    pub fn deinit(self: *Self) void {
        for (self.list.items) |*e| e.deinit(self.alloc);
        self.list.deinit();
    }

    /// Constuct command line for for the wakewords.
    pub fn toCmdline(self: *const Self, cmd_list: *std.ArrayList([:0]const u8)) !usize {
        var n: usize = 0;
        for (self.list.items) |e| {
            if (try e.toCmd(cmd_list.allocator)) |c| try cmd_list.append(c);
            n += 1;
        }
        return n;
    }

    pub fn details(self: *const Self) void {
        ll.info("List of wake words, mask={b}", .{self.mask});
        for (self.list.items) |e| e.details();
    }
};
/// Loads wakewords models form base_dir
/// Models are .tflite files
/// max_www sets the limis of the maximun number of models to consider
fn loadWakewords(alloc: std.mem.Allocator, base_dir: []const u8, max_ww: u8) !std.ArrayList(WwInfo) {
    var list = try std.ArrayList(WwInfo).initCapacity(alloc, max_ww);
    errdefer list.deinit();

    const base = try std.fs.realpathAlloc(alloc, base_dir);
    defer alloc.free(base);
    ll.info("Loding wakewords models from '{s}'", .{base});

    var dir = try std.fs.openIterableDirAbsolute(base, .{});
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();
    var i: u8 = 0;

    while (try walker.next()) |e| {
        if (e.kind == .file and std.mem.endsWith(u8, e.basename, ".tflite")) {
            var split = std.mem.split(u8, e.basename, ".tflite");
            if (split.next()) |n| {
                if (n.len > 0) {
                    const full_path = try std.fs.path.join(alloc, &([_][]const u8{ base, e.path }));
                    defer alloc.free(full_path);
                    var ww = try WwInfo.init(alloc, full_path, i);
                    @memset(&ww.status.name, 0);
                    if (n.len > 32) @memcpy(ww.status.name[0..32], n[0..32]) else @memcpy(ww.status.name[0..n.len], n[0..n.len]);
                    try list.append(ww);
                }
            }
        }
        // Exit condition by max items
        i += 1;
        if (i >= max_ww) break;
    }

    return list;
}

// ---------- Child process management --------
// --------------------------------------------

/// Child process manager
pub const Child = struct {
    child: ?std.ChildProcess = null,
    exe_arg: std.ArrayList([:0]const u8),
    alloc: std.mem.Allocator,
    mode: ChildMode = .None,

    const ChildMode = enum { None, WakeWord, Processor };
    const Self = @This();

    pub fn init(alloc: std.mem.Allocator) !Self {
        return Self{
            .exe_arg = try std.ArrayList([:0]const u8).initCapacity(alloc, 32),
            .alloc = alloc,
        };
    }

    fn cleanArgs(self: *Self) void {
        for (self.exe_arg.items) |a| self.alloc.free(a);
        self.exe_arg.clearRetainingCapacity();
    }

    fn start(self: *Self) !void {
        //errdefer self.stop();
        var cml = std.ArrayList(u8).init(self.alloc);
        defer cml.deinit();
        for (self.exe_arg.items) |e| {
            try cml.appendSlice(e);
            try cml.append(' ');
        }
        ll.info("{s}", .{cml.items});

        var child = std.ChildProcess.init(self.exe_arg.items, self.alloc);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        self.child = child;
    }

    pub fn stop(self: *Self) !void {
        if (self.child) |*ch| {
            //_ch.kll(); // send TERM signal
            ch.stdin.?.close();
            ch.stdin = null;
            _ = try ch.wait();
        }
        self.child = null;
        self.mode = .None;
        self.cleanArgs();
    }

    pub fn startWw(self: *Self, wwlist: WwList, audio_conf: AudioConf, models_path: [:0]const u8) !void {
        if (self.child != null) try self.stop() else self.cleanArgs(); // Clear current
        errdefer self.cleanArgs(); // In case of error deallocate the exe args list.
        const exe_path = try util.absPathExe(self.alloc, null, "voz-oww");
        try self.exe_arg.append(exe_path);
        const itype = try self.alloc.dupeZ(u8, "--audio=raw");
        try self.exe_arg.append(itype);
        const otype = try self.alloc.dupeZ(u8, "--output=machine");
        try self.exe_arg.append(otype);
        const modelp = try std.fmt.allocPrintZ(self.alloc, "--modelsdir={s}", .{models_path});
        try self.exe_arg.append(modelp);
        const aconf = try audio_conf.toCmd(self.alloc, false);
        try self.exe_arg.appendSlice(aconf[0..3]);
        _ = try wwlist.toCmdline(&self.exe_arg);

        try self.start();
        self.mode = .WakeWord;
    }

    pub fn startPre(self: *Self, audio_conf: AudioConf) !void {
        if (self.child != null) try self.stop() else self.cleanArgs();
        errdefer self.cleanArgs();
        const exe_path = try util.absPathExe(self.alloc, null, "voz-pre");
        try self.exe_arg.append(exe_path);
        const itype = try self.alloc.dupeZ(u8, "--audio=raw");
        try self.exe_arg.append(itype);
        const otype = try self.alloc.dupeZ(u8, "--output=raw");
        try self.exe_arg.append(otype);
        const aconf = try audio_conf.toCmd(self.alloc, true);
        try self.exe_arg.appendSlice(aconf[0..4]);

        try self.start();
        self.mode = .Processor;
    }
    pub inline fn pollStdout(self: *const Self) std.os.pollfd {
        return std.os.pollfd{ .fd = self.child.?.stdout.?.handle, .events = std.os.POLL.IN, .revents = undefined };
    }
    pub inline fn pollStderr(self: *const Self) std.os.pollfd {
        return std.os.pollfd{ .fd = self.child.?.stderr.?.handle, .events = std.os.POLL.IN, .revents = undefined };
    }

    pub inline fn isRunning(self: *const Self) bool {
        return self.child != null;
    }

    pub fn write(self: *Self, buf: []const u8) !usize {
        if (!self.isRunning()) return 0;
        const writer = self.child.?.stdin.?.writer();
        return try writer.write(buf);
    }

    pub fn read(self: *Self, buf: []u8, audio_conf: AudioConf) !ChildEvent {
        return switch (self.mode) {
            .None => .None,
            .Processor => blk: {
                const reader = self.child.?.stdout.?.reader();
                // The preprocessor ouputs audio fixed size audio prefix plus a one byte if vad is activated
                if (audio_conf.vad != 0) {
                    buf[0] = reader.readByte() catch |err| if (err == error.EndOfStream) return .Eof else return err;
                } else buf[0] = 0;
                const fixed_read = SAMPLES_40MS * @sizeOf(i16);
                const readed = try reader.read(buf[1 .. 1 + fixed_read]);
                break :blk if (readed == fixed_read) ChildEvent{ .BAudio = .{ buf[0], buf[1 .. 1 + fixed_read] } } else .Eof;
            },
            .WakeWord => blk: {
                const reader = self.child.?.stdout.?.reader();
                var bstream = std.io.fixedBufferStream(buf); // Virtual writer to the bufered stream.

                // Read line as all events are single line
                _ = reader.streamUntilDelimiter(bstream.writer(), '\n', buf.len) catch |err| switch (err) {
                    error.EndOfStream => break :blk .Eof,
                    else => return err,
                };

                // Parse event
                // Events are in format
                // R:<0/1> Ready or not ready
                // P:<index>:<score>:<count>
                const ev = bstream.getWritten();
                if (ev.len < 3) break :blk .None;

                const resEvent = switch (ev[0]) {
                    'R' => ChildEvent{ .WwReady = ev[2] == '1' },
                    'P' => iblk: {
                        if (WwMatch.fromSlice(ev[2..])) |m| {
                            break :iblk ChildEvent{ .WwMatch = m };
                        } else |err| {
                            ll.warn("Malformed child 'P' event'{s}' err={}", .{ ev, err });
                            break :iblk .None;
                        }
                    },
                    else => iblk: {
                        ll.warn("Invalid child event => '{s}'", .{ev});
                        break :iblk .None;
                    },
                };
                break :blk resEvent;
            },
        };
    }

    pub fn readLog(self: *const Self, buf: []u8) !?ChildEvent {
        if (self.child == null) return null;
        const reader = self.child.?.stderr.?.reader();
        var bstream = std.io.fixedBufferStream(buf); // Virtual writer

        _ = reader.streamUntilDelimiter(bstream.writer(), '\n', buf.len) catch |err| if (err == error.EndOfStream) return .Eof else return err;

        const written = bstream.getWritten();
        return if (written.len == 0) null else ChildEvent{ .Log = written };
    }

    pub inline fn resetSignal(self: *Self) !void {
        if (self.child) |c| try std.os.kill(c.id, std.os.SIG.USR1);
    }

    pub fn deinit(self: *Self) void {
        self.stop() catch {};
        self.exe_arg.deinit();
    }

    /// Child events
    pub const ChildEvent = union(enum) {
        ///No event was detected
        None: void,
        /// Eof event when reading the pipe
        Eof: void,
        /// Wakeword detection is ready true/false
        WwReady: bool,
        /// Audio chunk with vad information
        BAudio: struct { u8, []const u8 },
        /// Wakeword match.
        WwMatch: WwMatch,
        /// Log from sterr
        Log: []const u8,
    };
};

// ------ Control -----------
// --------------------------

/// Control object
pub const Control = struct {
    /// Reference for oww models path
    base_models_path: [:0]const u8,
    /// Internal Status
    status: Status = .{},
    /// Fd for poll.
    fdp: [3]std.os.pollfd = undefined,
    /// WakewordList
    ww_list: WwList,
    /// Child process
    child: Child,
    /// Serial interface reader
    dev_reader: std.fs.File.Reader,
    /// Serial interface writer
    dev_writer: std.fs.File.Writer,

    /// Internal static buffer for storing temporal data. + 1 is for vad byte.
    internal_buffer: [(SAMPLES_40MS * @sizeOf(i16)) + 1]u8 = undefined,
    /// Internal buffer for stderr from childs
    log_buffer: [1024]u8 = undefined,

    const Self = @This();
    const POLL_TIME_MS: i32 = 500;

    pub fn init(alloc: std.mem.Allocator, dev_serial: std.fs.File, ww_path: []const u8, models_path: [:0]const u8) !Self {
        var fdp: [3]std.os.pollfd = undefined;
        fdp[0] = std.os.pollfd{ .fd = dev_serial.handle, .events = std.os.POLL.IN, .revents = undefined };

        var wwl = try WwList.load(alloc, ww_path);
        errdefer wwl.deinit();
        const child = try Child.init(alloc);
        var sta = Status{ .n_wakewords = @as(u8, @intCast(wwl.len())), .wakeword_mask = wwl.mask };

        return Self{
            .base_models_path = models_path,
            .ww_list = wwl,
            .child = child,
            .dev_reader = dev_serial.reader(),
            .status = sta,
            .fdp = fdp,
            .dev_writer = dev_serial.writer(),
        };
    }

    pub inline fn isInMode(self: *const Self, m: ModeId) bool {
        return self.status.mode == m;
    }

    /// Result from poll
    pub const PollResult = struct {
        timed_out: bool = undefined,
        serial_event: ?Event = null,
        child_event: ?Child.ChildEvent = null,
        child_log: ?Child.ChildEvent = null,
    };

    /// Perform a single poll from event sources.
    pub fn poll(self: *Self) !PollResult {
        const poll_size: usize = if (self.child.isRunning()) 3 else 1;

        var c = try std.os.poll(self.fdp[0..poll_size], POLL_TIME_MS);
        var result: PollResult = .{ .timed_out = (c == 0) };
        if (c == 0) return result;

        if (c > 0 and (self.fdp[0].revents & std.os.POLL.IN) != 0) {
            // Input from serial
            var soh: u8 = 0;
            while (soh != SOH) {
                soh = self.dev_reader.readByte() catch |err| {
                    ll.err("can't read serial SOH => {}", .{err});
                    self.status.sta = .SerialIoError;
                    break;
                };
            }

            if (soh == SOH) {
                result.serial_event = Event.readEvent(self.dev_reader, false, &self.internal_buffer) catch |err| switch (err) {
                    error.NoSOH, error.HeaderIntegrity, error.PayloadTooBig, error.InvalidPayloadLen, error.PayloadChecksum, error.UnknownEvent, error.IncompleteEvent => blk: {
                        ll.warn("Serial event not readed:{}", .{err});
                        break :blk null;
                    },
                    else => blk: {
                        ll.err("can't read serial events => {}", .{err});
                        self.status.sta = .SerialIoError;
                        break :blk null;
                    },
                };
            }
            c -= 1;
        }

        if (poll_size > 1 and c > 0 and (self.fdp[1].revents & (std.os.POLL.IN | std.os.POLL.HUP)) != 0) {
            //std.os.POLL.HUP
            // Input from stdout of the child this will produce events
            result.child_event = self.child.read(&self.internal_buffer, self.status.audio_conf) catch |err| blk: {
                ll.err("can't read events from child => {}", .{err});
                self.status.sta = .ChildIoError;
                break :blk null;
            };
            c -= 1;
        }

        if (poll_size > 2 and c > 0 and (self.fdp[2].revents & (std.os.POLL.IN | std.os.POLL.HUP)) != 0) {
            // Imput from stderr
            result.child_log = self.child.readLog(&self.log_buffer) catch |err| blk: {
                ll.err("can't read log output form child => {}", .{err});
                self.status.sta = .ChildIoError;
                break :blk null;
            };
        }
        return result;
    }

    ///Reads the child's log without polling
    pub fn readLog(self: *Self) !?Child.ChildEvent {
        return self.child.readLog(&self.log_buffer);
    }

    pub fn deinit(self: *Self) void {
        self.child.deinit();
        self.ww_list.deinit();
    }

    // ---- Actions -----
    inline fn updateFDP(self: *Self) void {
        self.fdp[1] = self.child.pollStdout();
        self.fdp[2] = self.child.pollStderr();
    }

    fn sendSerialEvent(self: *Self, e: Event, flush: bool) void {
        const n = e.write(self.dev_writer, true) catch |err| blk: {
            ll.err("Failed to send serial event => {}", .{err});
            self.status.sta = .SerialIoError;
            break :blk 0;
        };
        _ = flush;
        _ = n;
        //if (flush and n > 0) self.dev_buf_writer.flush() catch |err| {
        //    ll.err("Failed to send serial event on flush => {}", .{err});
        //    self.status.sta = .SerialIoError;
        //};
    }

    ///Send status to FE
    pub inline fn sendStatus(self: *Self, flush: bool) void {
        self.sendSerialEvent(Event{ .Status = self.status }, flush);
    }
    ///change operating mode
    pub fn changeMode(self: *Self, new_mode: ModeId) void {
        self.status.mode = switch (new_mode) {
            .Idle => blk: {
                self.child.stop() catch |err| {
                    ll.err("Error stopping child to .Idle => {}", .{err});
                    self.status.sta = .InternalError;
                };
                break :blk .Idle;
            },
            .Preprocessor => blk: {
                self.child.startPre(self.status.audio_conf) catch |err| {
                    ll.err("Error creating child process(PRE) => {}", .{err});
                    self.status.sta = .InternalError;
                    break :blk .Idle;
                };
                self.updateFDP();
                break :blk .Preprocessor;
            },
            .WakeWord => blk: {
                self.child.startWw(self.ww_list, self.status.audio_conf, self.base_models_path) catch |err| {
                    ll.err("Error creating child process(PRE) => {}", .{err});
                    self.status.sta = .InternalError;
                    break :blk .Idle;
                };
                self.updateFDP();
                break :blk .WakeWord;
            },
            _ => blk: {
                self.child.stop() catch {};
                break :blk .Idle;
            },
        };
        if (self.status.mode != .Idle) std.time.sleep(750 * std.time.ns_per_ms); // Give some time to start the child as fast as possible.
        self.sendStatus(true);
    }
    ///Change audio configuration
    pub inline fn changeAudioConf(self: *Self, new_audio_conf: AudioConf) void {
        self.status.audio_conf = new_audio_conf;
        self.changeMode(self.status.mode);
    }
    ///Stream Audio to child process.
    pub fn streamAudio(self: *Self, a: []const u8) void {
        if (self.status.refrac > 0) {
            self.status.refrac -= 1;
            return;
        }
        _ = self.child.write(a) catch |err| {
            ll.err("Could not write audito to child {}", .{err});
            self.status.sta = .ChildIoError;
            self.sendStatus(true);
        };
    }
    ///Send WW list
    pub fn sendWwList(self: *Self, clear: bool) void {
        for (0..self.ww_list.len()) |i| {
            var st = self.ww_list.item(i).?;
            if (clear) st.status.conf.enabled = 0;
            const ev = Event{ .WwStatus = st.status };
            self.sendSerialEvent(ev, false);
        }

        if (clear) self.status.wakeword_mask = self.ww_list.updateMask(); // update mask if clear requested.
        self.sendStatus(true);
    }
    ///Change WwConf
    pub fn changeWwConf(self: *Self, c: WwConf) void {
        if (self.ww_list.item(c.index)) |w| {
            w.status.conf.enabled = c.enabled;
            w.status.conf.threshold = c.threshold;
            w.status.conf.patience = c.patience;
            const ev = Event{ .WwStatus = w.status };
            self.sendSerialEvent(ev, false);
        } else return;

        self.status.wakeword_mask = self.ww_list.updateMask(); // Update the mask
        self.changeMode(self.status.mode); // restart child
    }

    ///Reset the audio stream with refrac factor
    pub fn resetAudioStream(self: *Self, refrac: u8) void {
        self.status.refrac = refrac;
        self.child.resetSignal() catch |err| {
            ll.err("Can't signal child for audio stream reseting => {}", .{err});
            self.status.sta = .InternalError;
        };
    }
    /// Send a match over serial
    pub inline fn sendMatch(self: *Self, m: WwMatch) void {
        const ev = Event{ .WwMatch = m };
        self.sendSerialEvent(ev, true);
    }
};
