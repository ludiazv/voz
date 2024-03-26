//! Module for manage GPIOs in a specific thread.
//!
const std = @import("std");
const gpio = @import("gpio");
const rollbuffer = @import("rollbuffer.zig");

const ll = std.log.scoped(.Gpio);

pub const GpioAction = enum(u8) {
    On,
    Off,
    Blink,
    Int,
    Quit,
};

pub const GpioController = struct {
    chip_led: ?gpio.Chip = null,
    chip_int: ?gpio.Chip = null,
    line_led: ?gpio.Line = null,
    line_int: ?gpio.Line = null,
    action_rb: rollbuffer.RollBufferTS(GpioAction),
    alloc: std.mem.Allocator,
    running: bool = false,

    const Self = @This();

    const INT_MS: u64 = 10;
    const BLINK_MS: u64 = 350;

    const GpioSpec = struct {
        dev_path: [512 + 1]u8,
        pin_number: u32,
    };

    fn parseSpec(spec: []const u8) !GpioSpec {
        if (std.mem.indexOfScalar(u8, spec, ':')) |pos| {
            var res: GpioSpec = undefined;
            @memset(&res.dev_path, 0);
            _ = try std.fmt.bufPrint(&res.dev_path, "/dev/{s}", .{spec[0..pos]});
            res.pin_number = try std.fmt.parseInt(u32, spec[pos + 1 ..], 10);
            return res;
        } else return error.InvalidArgument;
    }

    pub fn init(alloc: std.mem.Allocator, led_spec: ?[]const u8, int_spec: ?[]const u8) !Self {

        // Allocate roll buffer.
        const rb = try rollbuffer.RollBufferTS(GpioAction).init(alloc, 10, false);
        errdefer rb.deinit();

        const led = if (led_spec) |ls| try Self.parseSpec(ls) else null;
        const int = if (int_spec) |is| try Self.parseSpec(is) else null;

        const is_same_chip = led != null and int != null and std.mem.eql(u8, &led.?.dev_path, &int.?.dev_path);

        var res: Self = .{ .alloc = alloc, .action_rb = rb };

        if (led) |ls| {
            res.chip_led = try gpio.getChip(&ls.dev_path);
            errdefer res.chip_led.?.close();
            res.chip_led.?.setConsumer("voz-ser") catch {};
            res.line_led = try res.chip_led.?.requestLine(ls.pin_number, .{ .output = true });
            errdefer res.line_led.?.close();
            ll.info("LED Gpio line {d} on chip '{s}' opened", .{ ls.pin_number, ls.dev_path });
        }

        if (int) |ii| {
            res.chip_int = if (is_same_chip) res.chip_led else try gpio.getChip(&ii.dev_path);
            errdefer res.chip_int.?.close();
            res.chip_int.?.setConsumer("voz-ser") catch {};
            res.line_int = try res.chip_int.?.requestLine(ii.pin_number, .{ .output = true });
            res.line_int.?.setHigh() catch {};
            ll.info("INT Gpio line {d} on chip '{s}' opened", .{ ii.pin_number, ii.dev_path });
        }

        return res;
    }

    pub fn deinit(self: *Self) void {
        self.action_rb.deinit();
        if (self.line_led) |l| l.close();
        if (self.line_int) |l| l.close();
        if (self.chip_led) |c| c.close();
        if (self.chip_int) |c| c.close();
    }

    fn processGpio(self: *Self) void {
        self.running = true;
        defer self.running = false;
        defer ll.info("Gpio thread finished", .{});

        ll.info("Gpio thread started...", .{});

        while (true) {
            var lrb = self.action_rb.waitAny();
            if (lrb.isFlagged()) break;
            const act = lrb.get()[0];
            lrb.roll(1);
            lrb.release();

            switch (act) {
                .Quit => break,
                .On => if (self.line_led) |l| l.setHigh() catch {},
                .Off => if (self.line_led) |l| l.setLow() catch {},
                .Int => if (self.line_int) |i| {
                    i.setLow() catch {};
                    std.time.sleep(INT_MS * std.time.ns_per_ms);
                    i.setHigh() catch {};
                },
                .Blink => if (self.line_led) |l| {
                    l.setHigh() catch {};
                    std.time.sleep(BLINK_MS * std.time.ns_per_ms);
                    l.setLow() catch {};
                },
            }
        }
    }

    pub fn run(self: *Self) !std.Thread {
        if (self.running) return std.Thread.SpawnError.ThreadQuotaExceeded;

        return std.Thread.spawn(std.Thread.SpawnConfig{}, Self.processGpio, .{self});
    }

    pub inline fn stop(self: *Self) void {
        self.action_rb.cancel();
    }

    pub inline fn action(self: *Self, act: GpioAction) void {
        _ = self.action_rb.appendOne(&act);
    }
};
