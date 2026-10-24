const std = @import("std");

threadlocal var thread_context_local: ?*ThreadContext = null;

pub const ThreadContext = struct {
    scratch: std.heap.ArenaAllocator,
    lane: Lane = .single,

    pub fn init(gpa: std.mem.Allocator) !*ThreadContext {
        const tctx = try gpa.create(ThreadContext);
        const arena = std.heap.ArenaAllocator.init(gpa);
        tctx.* = .{ .scratch = arena };
        return tctx;
    }

    pub fn deinit(tctx: *ThreadContext, gpa: std.mem.Allocator) void {
        tctx.scratch.deinit();
        gpa.destroy(tctx);
    }

    pub fn select(tctx: *ThreadContext) void {
        thread_context_local = tctx;
    }

    pub fn selected() Error!*ThreadContext {
        return if (thread_context_local == null)
            error.uninitialized
        else
            thread_context_local.?;
    }

    /// set the lane, returning previous lane (for nesting purposes)
    pub fn setLane(tctx: *ThreadContext, lane: Lane) Error!Lane {
        const prev_lane = tctx.lane;
        tctx.lane = lane;
        return prev_lane;
    }
};

pub const Lane = union(enum) {
    single,
    grouped: struct {
        index: u32,
        count: u32,
        /// slice of memory shared by all lanes
        broadcast_memory: *[std.atomic.cache_line]u8,
        barrier: *Barrier,
    },

    /// Poison the lane group so every lane blocked in (or later entering) `sync`/`broadcast`
    /// returns `err`.  Intended to be called by whoever owns the lane's body when it fails.
    pub fn abort(lane: *Lane, io: std.Io, err: anyerror) void {
        if (lane.* == .single) return;
        lane.grouped.barrier.abort(io, err);
    }

    pub fn sync(lane: *Lane, io: std.Io) anyerror!void {
        // single lane case
        if (lane.* == .single) return;
        try lane.grouped.barrier.wait(io);
    }

    test sync {
        const num_lanes = 4;
        const io = std.testing.io;

        const Shared = struct {
            data: [num_lanes]u32 = @splat(0),
            ok: std.atomic.Value(u32) = .init(0),
        };
        var shared: Shared = .{};
        var barrier: Barrier = .{ .expected = num_lanes };
        var memory: [std.atomic.cache_line]u8 align(std.atomic.cache_line) = undefined;

        const Worker = struct {
            fn run(s: *Shared, b: *Barrier, mem: *[std.atomic.cache_line]u8, io_: std.Io, idx: u32) anyerror!void {
                var lane: Lane = .{ .grouped = .{
                    .index = idx,
                    .count = num_lanes,
                    .broadcast_memory = mem,
                    .barrier = b,
                } };
                s.data[idx] = idx + 1;
                try lane.sync(io_);
                // after sync, every lane sees every other lane's write
                for (s.data, 0..) |v, i| {
                    if (v == i + 1) _ = s.ok.fetchAdd(1, .monotonic);
                }
            }
        };

        var futures: [num_lanes]std.Io.Future(anyerror!void) = undefined;
        for (&futures, 0..) |*f, i| {
            f.* = try io.concurrent(Worker.run, .{ &shared, &barrier, &memory, io, @as(u32, @intCast(i)) });
        }
        for (&futures) |*f| try f.await(io);

        try std.testing.expectEqual(@as(u32, num_lanes * num_lanes), shared.ok.load(.monotonic));
    }

    pub fn broadcast(
        lane: *Lane,
        /// type of data being broadcast
        T: type,
        /// source pointer  on src lane, destination pointer on all other lanes
        broadcast_ptr: *T,
        /// index of the source lane
        src_lane_idx: u32,
        io: std.Io,
    ) anyerror!void {
        comptime {
            std.debug.assert(@sizeOf(T) <= std.atomic.cache_line);
        }

        // single lane case
        if (lane.* == .single) return;

        // copy to broadcast memory on source lane
        const len = @sizeOf(T);
        if (src_lane_idx == lane.grouped.index) {
            const src: []u8 = std.mem.asBytes(broadcast_ptr);
            const dst: []u8 = lane.grouped.broadcast_memory[0..len];
            std.debug.assert(src.len == len);
            std.debug.assert(dst.len == len);
            @memcpy(dst, src);
        }

        try lane.grouped.barrier.wait(io);

        // copy from broadcast memory on destination lanes
        if (src_lane_idx != lane.grouped.index) {
            const src: []u8 = lane.grouped.broadcast_memory[0..len];
            const dst: []u8 = std.mem.asBytes(broadcast_ptr);
            std.debug.assert(src.len == len);
            std.debug.assert(dst.len == len);
            @memcpy(dst, src);
        }

        // don't let the source lane reuse broadcast memory until everyone has read it
        try lane.grouped.barrier.wait(io);
    }

    test broadcast {
        const num_lanes = 4;
        const src_lane = 2;
        const io = std.testing.io;

        const Shared = struct {
            received: [num_lanes]u64 = @splat(0),
        };
        var shared: Shared = .{};
        var barrier: Barrier = .{ .expected = num_lanes };
        var memory: [std.atomic.cache_line]u8 align(std.atomic.cache_line) = undefined;

        const Worker = struct {
            fn run(s: *Shared, b: *Barrier, mem: *[std.atomic.cache_line]u8, io_: std.Io, idx: u32) anyerror!void {
                var lane: Lane = .{ .grouped = .{
                    .index = idx,
                    .count = num_lanes,
                    .broadcast_memory = mem,
                    .barrier = b,
                } };
                // only the source lane starts with the real value
                var value: u64 = if (idx == src_lane) 0xBEEF else 0;
                try lane.broadcast(u64, &value, src_lane, io_);
                s.received[idx] = value;
            }
        };

        var futures: [num_lanes]std.Io.Future(anyerror!void) = undefined;
        for (&futures, 0..) |*f, i| {
            f.* = try io.concurrent(Worker.run, .{ &shared, &barrier, &memory, io, @as(u32, @intCast(i)) });
        }
        for (&futures) |*f| try f.await(io);

        for (shared.received) |v| try std.testing.expectEqual(@as(u64, 0xBEEF), v);
    }
};

pub const Barrier = struct {
    /// number of expected waiters
    expected: u32,
    spin_limit: u32 = 256, // chosen by throwing a dart at the wall
    arrived: std.atomic.Value(u32) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    generation: std.atomic.Value(u32) = .init(0),
    /// `@intFromError` of the first error passed to `abort`, or 0 if not aborted.  Sticky.
    err: std.atomic.Value(u16) = .init(0),

    /// Poison the barrier: wake every waiter and make all current and future `wait`s return `e`.
    /// The first error wins.
    pub fn abort(barrier: *Barrier, io: std.Io, e: anyerror) void {
        _ = barrier.err.cmpxchgStrong(0, @intFromError(e), .release, .monotonic);
        // Change the futex word so a waiter that checked `err` just before this can't go to sleep.
        _ = barrier.generation.fetchAdd(1, .seq_cst);
        io.futexWake(u32, &barrier.generation.raw, std.math.maxInt(u32));
    }

    fn check(barrier: *Barrier) anyerror!void {
        const code = barrier.err.load(.acquire);
        if (code != 0) return @errorFromInt(code);
    }

    pub fn wait(barrier: *Barrier, io: std.Io) anyerror!void {
        // fail fast: an aborted barrier will never fill
        try barrier.check();

        // load generation before arriving
        const gen = barrier.generation.load(.monotonic);

        if (barrier.arrived.fetchAdd(1, .acq_rel) + 1 == barrier.expected) {
            // last arriver.  reset, release, and wake
            barrier.arrived.store(0, .monotonic);
            barrier.generation.store(gen +% 1, .seq_cst);
            if (barrier.sleepers.load(.seq_cst) != 0) {
                io.futexWake(u32, &barrier.generation.raw, std.math.maxInt(u32));
            }
            return;
        }

        // try spinning first
        var spins: u32 = 0;
        while (spins < barrier.spin_limit) : (spins += 1) {
            if (barrier.generation.load(.acquire) != gen) return barrier.check();
            std.atomic.spinLoopHint();
        }

        // otherwise sleep
        _ = barrier.sleepers.fetchAdd(1, .seq_cst);
        while (barrier.generation.load(.seq_cst) == gen) {
            io.futexWaitUncancelable(u32, &barrier.generation.raw, gen);
        }
        _ = barrier.sleepers.fetchSub(1, .monotonic);
        return barrier.check();
    }

    test wait {
        const num_lanes = 4;
        const rounds = 10_000;
        const spin_limit = 256;
        const io = std.testing.io;

        const Shared = struct {
            barrier: Barrier,
            data: [2][num_lanes]u32 = @splat(@splat(0)),
            failed: std.atomic.Value(bool) = .init(false),
        };
        var shared: Shared = .{ .barrier = .{ .expected = num_lanes, .spin_limit = spin_limit } };

        const Worker = struct {
            fn run(s: *Shared, io_: std.Io, idx: u32, rounds_: u32) anyerror!void {
                // Start at 1 so the zero-initialized buffers can never pass by accident.
                var round: u32 = 1;
                while (round <= rounds_) : (round += 1) {
                    const buf = &s.data[round & 1];
                    buf[idx] = round; // plain write, published only by the barrier
                    try s.barrier.wait(io_);
                    // every lane's write for this round must be visible
                    for (buf) |v| {
                        if (v != round) s.failed.store(true, .monotonic);
                    }
                }
            }
        };

        var futures: [num_lanes]std.Io.Future(anyerror!void) = undefined;
        for (&futures, 0..) |*f, i| {
            f.* = try io.concurrent(Worker.run, .{ &shared, io, @as(u32, @intCast(i)), rounds });
        }
        for (&futures) |*f| try f.await(io);

        try std.testing.expect(!shared.failed.load(.monotonic));
        try std.testing.expectEqual(rounds, shared.barrier.generation.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 0), shared.barrier.arrived.load(.monotonic));
    }

    test abort {
        const num_lanes = 4;
        const io = std.testing.io;

        // spin_limit = 0 forces waiters down the futex path
        var barrier: Barrier = .{ .expected = num_lanes, .spin_limit = 0 };

        const Worker = struct {
            fn run(b: *Barrier, io_: std.Io, idx: u32) anyerror!void {
                if (idx == 0) {
                    // aborting lane never reaches the barrier
                    b.abort(io_, error.TestAbort);
                    return error.TestAbort;
                }
                try b.wait(io_);
            }
        };

        var futures: [num_lanes]std.Io.Future(anyerror!void) = undefined;
        for (&futures, 0..) |*f, i| {
            f.* = try io.concurrent(Worker.run, .{ &barrier, io, @as(u32, @intCast(i)) });
        }
        // every lane, aborter and waiters alike, reports the same error
        for (&futures) |*f| try std.testing.expectError(error.TestAbort, f.await(io));

        // sticky: later waits fail immediately
        try std.testing.expectError(error.TestAbort, barrier.wait(io));
    }
};

pub const Range = struct { start: usize, end: usize };

pub const Error = error{
    uninitialized,
};

test {
    std.testing.refAllDecls(@This());
}
