//! This program is a simple Implements a serial protocol for audio.

const std = @import("std");
const clap = @import("clap");
const ser = @import("ser.zig");
const util = @import("util.zig");
const zig_serial = @import("serial");
const gpiod = @import("ser-gpio.zig");

const ll = std.log;

pub const log_level: std.log.Level = .debug;

const args = clap.parseParamsComptime(
    \\-h, --help                      Display this message.
    \\--version                       Show version.
    \\-d, --device          <DEV>     Required serial device (e.g. /dev/ttyS3). Must be absolute path. (default: /dev/ttyS1)
    \\-i, --int             <GPIO>    Signalize events with falling edge interrupt on gpio. (default: disabled)
    \\-l, --led             <GPIO>    Signalize activity using a on board led. (default: disabled)
    \\-m, --wwmodeldir      <PATH>    Path to the wake word models path to scan (default=<exe-path>/wwmodels)
    \\-b, --basemodeldir    <PATH>    Path to base models required form open wakeword (default=<exe-path>/models)
);

const some_help =
    \\ --int & --led are optional and should be provided with the following format:
    \\  gpiochip<N>:<line number>
    \\
    \\ Log information is written to stderr.
    \\ Relevant exit codes:
    \\ 0 => Normally finished do not require restart
    \\ 1 => Requesting restart Normal
    \\ 2 => Requesting restart with retry count
    \\ 5 => Fatal error should not restart.
    \\ 6 => Requested by TERM or INT
;

const ExitCode = enum(u8) {
    RetNormal = 0,
    RetRestart = 1,
    RetRestartRetry = 2,
    RetFatal = 5,
    RetRequested = 6,
};

const args_parsers = .{
    .DEV = clap.parsers.string,
    .GPIO = clap.parsers.string,
    .PATH = clap.parsers.string,
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

    // Init GPA
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer _ = gpa.deinit();
    //

    // Parse arguments
    const arg = try parseArgs(allocator);
    defer arg.deinit();

    // Print help
    if (arg.args.help != 0) {
        try stdout.writer().print("voz-ser - serial interface for voz-pre and voz-oww\n", .{});
        try clap.help(stdout.writer(), clap.Help, &args, .{});
        try stdout.writer().print("\n{s}\n", .{some_help});
        return @intFromEnum(ExitCode.RetNormal);
    }
    // Print version
    if (arg.args.version != 0) {
        stdout.writer().print("{s}\n", .{util.VOZ_VERSION}) catch unreachable;
        return @intFromEnum(ExitCode.RetNormal);
    }

    // Extract parameters
    const dev_path = arg.args.device orelse "/dev/ttyS1";
    const ww_path = try if (arg.args.wwmodeldir) |m| util.customPath(allocator, m, "") else util.absPathExe(allocator, "wwmodels", "");
    const model_path = try if (arg.args.basemodeldir) |m| util.customPath(allocator, m, "") else util.absPathExe(allocator, "models", "");
    defer allocator.free(ww_path);
    defer allocator.free(model_path);

    var gpio_control = if (arg.args.led != null or arg.args.int != null)
        // Init gpio control
        gpiod.GpioController.init(allocator, arg.args.led, arg.args.int) catch |err| {
            stderr.writer().print("Fatal error: could not init gpios => {}", .{err}) catch unreachable;
            return @intFromEnum(ExitCode.RetFatal);
        }
    else
        null;

    // TODO Check if ww_path exits.
    // Init Serial port
    var dev_serial = std.fs.cwd().openFile(dev_path, .{ .mode = .read_write }) catch |err| {
        stderr.writer().print("Fatal error: Could not open {s} => {}", .{ dev_path, err }) catch unreachable;
        return @intFromEnum(ExitCode.RetFatal);
    };
    defer dev_serial.close();

    // Configuer the serial port.
    {
        zig_serial.configureSerialPort(dev_serial, zig_serial.SerialConfig{
            .baud_rate = 576000,
            .word_size = 8,
            .parity = .none,
            .stop_bits = .one,
            .handshake = .none,
        }) catch |err| {
            stderr.writer().print("Fatal error: Could not configure serial {s} => {}", .{ dev_path, err }) catch unreachable;
            return @intFromEnum(ExitCode.RetFatal);
        };

        // Hack: as zig_serial does not support serial timeout we simply call termios on hte same handle.
        var settings = std.os.tcgetattr(dev_serial.handle) catch return 5;
        settings.cc[5] = 3; // VTIME is index 5. set the timeout to 200ms (2* tenths of secods)
        std.os.tcsetattr(dev_serial.handle, .NOW, settings) catch |err| {
            stderr.writer().print("Fatal error: Could not set serial port timeout {s} => {}", .{ dev_path, err }) catch unreachable;
            return @intFromEnum(ExitCode.RetFatal);
        };
    }

    ll.info("Configured serial port '{s}'", .{dev_path});
    ll.info("Starting control loop with ww_path={s} model_path={s}...", .{ ww_path, model_path });
    var control = ser.Control.init(allocator, dev_serial, ww_path, model_path) catch |err| {
        stderr.writer().print("Fatal error: Could not initiate serial controller => {}", .{err}) catch unreachable;
        return @intFromEnum(ExitCode.RetFatal);
    };
    control.ww_list.details();
    defer control.deinit();

    // register signal handlers
    try util.registerSignal(std.os.SIG.TERM, handleSignals);
    try util.registerSignal(std.os.SIG.INT, handleSignals);
    try util.registerSignal(std.os.SIG.CHLD, handleSignals);
    ll.info("Registered signals TERM, INT and CHLD", .{});

    const gpio_thread = if (gpio_control) |*gc| try gc.run() else null;
    if (gpio_control) |*gc| {
        gc.action(.Blink);
        gc.action(.Blink);
    }

    // Control loop
    zig_serial.flushSerialPort(dev_serial, true, true) catch unreachable; // Clear all serial buffers
    ll.info("Sending initial status..", .{});
    control.sendStatus(true); // Send status on startup

    ll.info("Starting serial service...", .{});
    var timer = try std.time.Timer.start();
    var audio_frames: u32 = 0;

    while (keep_running) {
        var child_stdout_eof: bool = false;
        var child_stderr_eof: bool = false;

        const elapsed = timer.read();
        if (elapsed > std.time.ns_per_s * 30) {
            ll.debug("Mode:{}, Status:{} Stats: Audio frames per second:{d} [should be ~25 when active]", .{ control.status.mode, control.status.sta, audio_frames / 30 });
            timer.reset();
            audio_frames = 0;
            control.sendStatus(true);
        }

        const pr = control.poll() catch |err| {
            // TODO manage err type
            ll.err("POLL ERR=>{}", .{err});
            keep_running = false;
            exit_code = ExitCode.RetFatal;
            continue;
        };

        if (pr.timed_out) continue; // On timeout simply continue the loop

        if (pr.serial_event) |se| switch (se) { // Process serial events
            .Nop => {
                ll.info("Pong", .{});
                control.sendStatus(true);
            },
            .Reboot => {
                ll.info("Reboot", .{});
                exit_code = ExitCode.RetRestart;
                keep_running = false;
            },
            .Mode => |m| {
                ll.info("Mode change to {}", .{m});
                control.changeMode(m);
            },
            .Areset => |r| {
                ll.info("Audio Reset", .{});
                control.resetAudioStream(r);
            },
            .Config => |c| {
                ll.info("Change audio config to {}", .{c});
                control.changeAudioConf(c);
            },
            .Audio => |audio| {
                control.streamAudio(audio);
                audio_frames += 1;
            },
            .WwList => |n| {
                ll.info("Request wakeword list with clear={}", .{n});
                control.sendWwList(n);
            },
            .WwConf => |c| {
                ll.info("Change wakeword config for {}", .{c});
                control.changeWwConf(c);
            },
            else => ll.warn("Unexepected serial event '{}'", .{se}),
        };

        if (pr.child_event) |ce| switch (ce) {
            .Eof => child_stdout_eof = true,
            .WwReady => |b| ll.info("Wakeword detection is ready={}", .{b}),
            .WwMatch => |m| {
                control.sendMatch(m);
                if (gpio_control) |*gc| {
                    gc.action(.Int);
                    gc.action(.Blink);
                }
            },
            else => ll.warn("Unexpected child event '{}'", .{ce}),
        };

        if (pr.child_log) |cl| switch (cl) {
            .Eof => child_stderr_eof = true,
            .Log => |buf| {
                stderr.writer().writeAll(buf) catch {};
                stderr.writer().writeByte('\n') catch {};
            },
            else => ll.warn("Unexpected child log event '{}'", .{cl}),
        };

        // Child EOF condition.
        if (child_stdout_eof or child_stderr_eof) {
            ll.warn("Unexpected child EOF detected [stdout={},stderr={}]", .{ child_stdout_eof, child_stderr_eof });
            if (!child_stderr_eof) {
                // Try to read the full stderr
                while (control.readLog() catch null) |ce| {
                    switch (ce) {
                        .Eof => break,
                        .Log => |buf| {
                            stderr.writer().writeAll(buf) catch {};
                            stderr.writer().writeByte('\n') catch {};
                        },
                        else => {},
                    }
                }
            }
        }

        //Error condition
        switch (control.status.sta) {
            .Normal => continue,
            .SerialIoError, .ChildIoError, .InternalError => if (!control.isInMode(.Idle)) control.changeMode(.Idle),
        }
    }

    if (gpio_control) |*gc| gc.action(.Quit);
    if (gpio_thread) |*gt| gt.join();

    return @intFromEnum(exit_code);
}

var keep_running: bool = true;
var exit_code: ExitCode = ExitCode.RetRestart;
var sig_chld: bool = false;

fn handleSignals(sig: c_int) callconv(.C) void {
    switch (sig) {
        std.os.SIG.TERM, std.os.SIG.INT => {
            keep_running = false;
            exit_code = ExitCode.RetRequested;
            ll.info("Termination Signal {d} received. Gracefully terminating.", .{sig});
        },
        std.os.SIG.CHLD => {
            ll.info("CHLD signal {d} received.", .{sig});
        },
        else => unreachable,
    }
}
