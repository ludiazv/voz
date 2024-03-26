//! Utility roling buffer
//! naked & thread safe implementation of effiecint rollbuffer.
//! A rollbuffer is a contiguous space of memory with fixed capacity with fifo logic.
//!
//! Data is feed to the buffer via append() method that adds data to the tail of the buffer.
//! On append if the buffer capacity is not suffient the data will be shitfted
//!
/// A Thread safe implementation with condition handling to simplify communication btw threads.
/// init & deinit call should placed on safe place (e.g. main thread)
///
/// Typical usage:
/// A typical scenario to communicate 2 threads via rollobuffer one procducer -> consumer.
///
///  The producer will tipically feed the roll buffer using append().
///  The consumer will wait for the buffer to specific size to start processing.
///    1. The consumer will wait using rb.waitAtLeast*(minum number of items to wait)
///    2. The producer will append data to the buffer via rb.append(); (this will signal and wake the consumer)
///    3. The consumer awakes a return the naked rollbuffer that can be accessed as it is locked.
///    4. The consumer must release buffer to enable the producer to push additional data by calling release()
///
///
const std = @import("std");

pub const RollBufferStatus = struct {
    cancel: bool,
    reset: bool,

    pub inline fn isFlagged(self: @This()) bool {
        return self.cancel or self.reset;
    }
    pub inline fn clean(self: *@This()) void {
        self.cancel = false;
        self.reset = false;
    }
};

/// Locked Thread-safe rollbuffer.
pub fn LockedRollBuffer(comptime T: type) type {
    return struct {
        parent: *RollBufferTS(T),
        rb: *RollBufferTS(T).innerType,

        const Self = @This();

        pub inline fn isFlagged(self: *const Self) bool {
            return self.parent.status.isFlagged();
        }

        pub inline fn get(self: *const Self) []T {
            return self.rb.get();
        }
        pub inline fn status(self: *const Self) RollBufferStatus {
            return self.parent.status;
        }

        pub inline fn roll(self: *Self, n: usize) void {
            self.rb.roll(n);
        }

        pub inline fn reset(self: *Self) void {
            self.rb.reset();
        }

        pub inline fn len(self: *const Self) usize {
            return self.rb.len();
        }

        pub inline fn append(self: *Self, elements: []const T) usize {
            return self.rb.append(elements);
        }

        pub inline fn appendOne(self: *Self, e: *const T) usize {
            return self.rb.appendOne(e);
        }

        pub inline fn release(self: *Self) void {
            self.parent.m.unlock();
        }

        pub fn releaseAndSignal(self: *Self) void {
            self.parent.status.clean();
            self.release();
            if (self.parent.broadcast) self.parent.condition.broadcast() else self.parent.condition.signal();
        }
    };
}

/// Thread-safe rollbuffer
pub fn RollBufferTS(comptime T: type) type {
    return struct {
        condition: std.Thread.Condition,
        m: std.Thread.Mutex,
        rb: RollBuffer(T),
        broadcast: bool,
        status: RollBufferStatus = RollBufferStatus{ .cancel = false, .reset = false },

        const Self = @This();

        pub const innerType = RollBuffer(T);

        /// Init
        pub fn init(allocator: std.mem.Allocator, max_capacity: usize, broadcast: bool) std.mem.Allocator.Error!Self {
            var rb = try innerType.init(allocator, max_capacity);
            return Self{ .condition = .{}, .m = .{}, .rb = rb, .broadcast = broadcast };
        }

        /// Deinit this not thread-safe please only when sure that no threads are using the buffer
        pub inline fn deinit(self: Self) void {
            self.rb.deinit();
        }

        // Safe append elements to the rollbuffer.
        // Note: Yields the current thread to activate the consumer.
        pub fn append(self: *Self, elements: []const T) usize {
            self.m.lock();
            var l = self.rb.append(elements);
            self.m.unlock();
            if (self.broadcast) self.condition.broadcast() else self.condition.signal();
            std.Thread.yield() catch {};
            return l;
        }
        pub fn appendOne(self: *Self, e: *const T) usize {
            self.m.lock();
            const added = self.rb.appendOne(e);
            self.m.unlock();
            if (self.broadcast) self.condition.broadcast() else self.condition.signal();
            std.Thread.yield() catch {};
            return added;
        }

        // Reset the buffer and signals. (typically called by the producer)
        // This flag could be used to the consumer to perform differentaction
        // Note: Yields the current thread to activate the consumer.
        pub fn reset(self: *Self) void {
            self.m.lock();
            self.rb.reset();
            self.status.reset = true;
            self.m.unlock();
            if (self.broadcast) self.condition.broadcast() else self.condition.signal();
            std.Thread.yield() catch {};
        }

        // set the ring buffer to cancel mode. The producer will no provide any addtional data
        // This signal the EOF of the stream.
        // Note: Yields the current thread to activate the consumer.
        pub fn cancel(self: *Self) void {
            self.m.lock();
            self.status.cancel = true;
            self.m.unlock();
            if (self.broadcast) self.condition.broadcast() else self.condition.signal();
            std.Thread.yield() catch {};
        }

        // Safe check if is cancelled.
        //pub fn isCancelled(self: *Self) bool {
        //    self.m.lock();
        //    defer self.m.unlock();
        //    return self.is_cancel;
        //}
        // Usafe check if the roll buffer is cancelled.
        // to call this method is required to lock the rb before by lockRb method.
        //pub fn unsafe_isCancelled(self: *Self) bool {
        //    return self.is_cancel;
        //}

        /// Returns a pointer to the internal roll buffer. Its unsafe and only use if you know what you doing.
        //pub fn unsafe_rb(self: *Self) *innerType {
        //    return &self.rb;
        //}

        /// Return the capacity. This is safe as capacity is constant on init.
        pub inline fn capacity(self: *const Self) usize {
            return self.rb.capacity(); // this is safe as capacity is constant.
        }

        pub fn lock(self: *Self) LockedRollBuffer(T) {
            self.m.lock();
            return LockedRollBuffer(T){ .parent = self, .rb = &self.rb };
        }
        /// consumer wait for n Items. Returns a pointer to locked unsafe rollbuffer after treatement a call to release is needed.
        /// The return value is a tuple with the roll buffer and the status of is_flaged
        pub fn waitAtLeast(self: *Self, n: usize) LockedRollBuffer(T) {
            self.m.lock();
            var rb = &self.rb;
            while (rb.len() < n and !self.status.isFlagged()) self.condition.wait(&self.m);

            return LockedRollBuffer(T){ .parent = self, .rb = &self.rb };
        }

        pub inline fn waitAny(self: *Self) LockedRollBuffer(T) {
            return self.waitAtLeast(1);
        }
    }; // Struct RollBufferTS

}

/// Rollbuffer naked. T is the type of each element in the buffer
pub fn RollBuffer(comptime T: type) type {
    return struct {
        /// Internal buffer
        buf: []T,
        cap: usize,
        head: usize,
        allocator: std.mem.Allocator,

        //Methods
        const Self = @This();
        const MIN_CAPACITY: usize = 1;

        /// init to create the buffer with a fixed max capacity
        pub fn init(allocator: std.mem.Allocator, max_capacity: usize) std.mem.Allocator.Error!Self {
            const cap = @max(max_capacity, MIN_CAPACITY);
            var b = try allocator.alloc(T, cap);
            return Self{ .buf = b, .allocator = allocator, .cap = cap, .head = 0 };
        }

        /// deinit
        pub fn deinit(self: Self) void {
            self.allocator.free(self.buf);
        }

        /// Reset the buffer discaring all data.
        pub fn reset(self: *Self) void {
            self.head = 0;
        }

        /// Return the actual length
        pub inline fn len(self: *const Self) usize {
            return self.head;
        }

        /// Returns the capacity of rollbuffer
        pub inline fn capacity(self: *const Self) usize {
            return self.cap;
        }

        /// Returs the free space on the buffer
        pub inline fn free(self: *const Self) usize {
            return self.cap - self.head;
        }

        /// Is the buffer empty?
        pub inline fn empty(self: *const Self) bool {
            return self.head == 0;
        }

        /// Roll the buffer [n] items
        pub fn roll(self: *Self, n: usize) void {
            // Reset
            if (n == 0) return; // roll 0 is nop
            if (n >= self.head) { // roll more or equal that stored is reset
                self.reset();
            } else { // copy to the begining of the buffer the tail part
                //std.debug.print("requested rol n={}\n", .{n});
                // TODO optimize with memcpy for non overlapping part
                // copy non overlaping part with a single memcpy
                //const non_ovelap = n + n;
                //const over_lap = self.head - non_ovelap;
                //@memcpy(self.buf, self.buf[n..non_ovelap]);
                // copy the rest with forwards copy
                //if (over_lap > 0) std.mem.copyForwards(T, self.buf[n .. self.head - n], self.buf[non_ovelap..self.head]);
                std.mem.copyForwards(T, self.buf, self.buf[n..self.head]);
                self.head -= n;
            }
        }

        /// Append [elements] to the end tail of buffer rolling the buffer if necesary. Returns the total items added.
        /// if the number of elements to add are bigger than the capacity only the tail part of the elments will be added
        /// to the buffer. in this case the return value will be less than the length of elements add to the buffer
        pub fn append(self: *Self, elements: []const T) usize {
            const new = elements.len;
            if (new == 0) return 0; // empty add is a nop
            // free space
            const free_space = self.free();
            var added: usize = 0;
            // If no space free we try to make free space sufficient for copy (only limited by capacity)
            if (new > free_space) self.roll(new - free_space);
            //
            if (new <= self.cap) {
                @memcpy(self.buf[self.head .. self.head + new], elements[0..]);
                self.head += new;
                added = new;
                //std.debug.print("mcpy add head={},added={}\n", .{ self.head, added });
            } else {
                // elements is bigger than capacity we force rolling the input also.
                @memcpy(self.buf[0..], elements[new - self.cap ..]);
                self.head = self.cap;
                added = self.cap;
            }
            return added;
        }

        /// Append one element to the rollbuffer.
        pub fn appendOne(self: *Self, e: *const T) usize {
            if (self.free() == 0) self.roll(1);
            self.buf[self.head] = e.*;
            self.head += 1;
            return 1;
        }

        //pub fn appendOne(self: *Self, e: *const T) usize {
        //    const e_: []const T = @ptrCast(e);
        //    return self.append(e_);
        //}
        /// Get buffer data.
        pub fn get(self: *const Self) []T {
            return self.buf[0..self.head];
        }
    }; //RollBuffer Type

} // comptime RollBuffer

test "Rollbuffer" {
    const testing = std.testing;

    var r = try RollBuffer(u8).init(testing.allocator, 10);
    defer r.deinit();

    // Empty Rollbuffer
    try testing.expectEqual(@as(usize, 0), r.empty());
    try testing.expectEqual(@as(usize, 0), r.len());
    try testing.expectEqual(.{}, r.get());

    // Simple add
    const data: []const u8 = "ABC";
    try testing.expectEqual(data.len, r.append(data));
    try testing.expectEqual(data.len, r.len());
    try testing.expect(std.mem.eql(u8, data, r.get()));
    // Roll
    const roll = 2;
    r.roll(roll);
    try testing.expectEqual(@as(usize, data.len - roll), r.len());
    try testing.expect(std.mem.eql(u8, data[roll..], r.get()));
    //std.debug.print("\nafer roll '{s}'\n", .{r.get()});

    // Auto roll
    const datan: []const u8 = "NNNNN";
    const datam: []const u8 = "RRRR";
    const datafull: []const u8 = "9876543210";

    try testing.expectEqual(datan.len, r.append(datan));
    try testing.expectEqual(datan.len + 1, r.len());
    try testing.expect(std.mem.eql(u8, "C" ++ datan, r.get()));

    // Auto roll full
    try testing.expectEqual(datam.len, r.append(datam));
    try testing.expectEqual(@as(usize, 0), r.free());
    try testing.expect(std.mem.eql(u8, "C" ++ datan ++ datam, r.get()));

    try testing.expectEqual(datafull.len, r.append(datafull));
    try testing.expectEqual(@as(usize, 0), r.free());
    try testing.expect(std.mem.eql(u8, datafull, r.get()));

    // Autoroll with append bigger than capacity
    try testing.expectEqual(datafull.len, r.append(datam ++ datafull));
    try testing.expectEqual(@as(usize, 0), r.free());
    try testing.expect(std.mem.eql(u8, datafull, r.get()));

    // Reset
    r.reset();
    try testing.expectEqual(r.capacity(), r.free());
}
