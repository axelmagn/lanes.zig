const std = @import("std");
const assert = std.debug.assert;
const cache_line = std.atomic.cache_line;
const ArgsTuple = std.meta.ArgsTuple;

threadlocal var thread_context: ThreadContext = .uninitialized;

pub fn init(safe_gpa: std.mem.Allocator, threaded_io: *std.Io.Threaded) void {
    const arena = std.heap.ArenaAllocator.init(safe_gpa);
    thread_context = .{
        .initialized = true,
        .safe_gpa = safe_gpa,
        .io = threaded_io.io(),
        .arena = arena,
    };
}

pub const LaunchOptions = struct {
    pub const LanesMode = union(enum) {
        exact: u32,
        cpus,
    };
};

// pub fn launch(
//     function: anytype,
//     args: ArgsTuple(@TypeOf(function)),
//     opts: LaunchOptions,
// ) ReturnType(@TypeOf(function)) {
//
// }

pub fn getIndex() u32 {
    return thread_context.lane.index;
}

pub fn getCount() u32 {
    return thread_context.lane.count;
}

pub fn isLeader() bool {
    return thread_context.lane.isLeader();
}

pub fn isSingle() bool {
    return thread_context.lane.isSingle();
}

pub fn getIo() LanesError!std.Io {
    try expectInitialized();
    return thread_context.io;
}

pub fn getGpa() LanesError!std.mem.Allocator {
    try expectInitialized();
    return thread_context.safe_gpa;
}

pub fn getScratch() LanesError!std.heap.ArenaAllocator {
    try expectInitialized();
    return thread_context.arena;
}

pub fn sync() anyerror!void {
    const io = try getIo();
    try thread_context.lane.sync(io);
}

pub fn broadcast(T: type, broadcast_ptr: *T, source_lane_index: u32) anyerror!void {
    const io = try getIo();
    try thread_context.lane.broadcast(T, broadcast_ptr, source_lane_index, io);
}

fn expectInitialized() LanesError!void {
    if (!thread_context.initialized) return LanesError.uninitialized;
}

fn ReturnType(T: type) type {
    return @typeInfo(T).@"fn".return_type.?;
}

fn LaunchResult(comptime F: type) type {
    const R = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(R)) {
        .void => LanesError!void,
        .error_union => |eu| {
            if (eu.payload != void) @compileError("lane functions must return void or E!void");
            return (eu.error_set || LanesError)!void;
        },
        else => @compileError("lane functions must return void or E!void"),
    };
}

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(r: Range) usize {
        return r.end - r.start;
    }
};

pub const LanesError = error{
    uninitialized,
} || Barrier.Error;

const ThreadContext = struct {
    initialized: bool = false,

    io: std.Io,

    /// thread-safe general allocator
    safe_gpa: std.mem.Allocator,

    /// thread-local scratch arena
    arena: std.heap.ArenaAllocator,

    /// lane context data
    lane: Lane = .single,

    const uninitialized: ThreadContext = .{
        .initialized = false,
        .io = undefined,
        .safe_gpa = undefined,
        .arena = undefined,
        .lane = .single,
    };

    /// set the lane, returning previous lane (for nesting purposes)
    fn setLane(tctx: *ThreadContext, lane: Lane) Lane {
        assert(tctx.initialized);
        const prev_lane = tctx.lane;
        tctx.lane = lane;
        return prev_lane;
    }
};

/// The context describing how a thread fits into a group. It never makes sense
/// for there to be more lanes than threads.
const Lane = struct {
    index: u32,
    count: u32,
    /// slice of memory shared by all lanes
    broadcast_slot: *BroadcastSlot,
    barrier: *Barrier,

    const single: Lane = .{
        .index = 0,
        .count = 1,
        .broadcast_slot = undefined,
        .barrier = undefined,
    };

    const BroadcastSlot = struct {
        bytes: [cache_line]u8 align(cache_line) = undefined,
    };

    fn isLeader(lane: Lane) bool {
        return lane.index == 0;
    }

    fn isSingle(lane: Lane) bool {
        if (lane.count == 1) {
            std.debug.assert(lane.index == 0);
            return true;
        }
        return false;
    }

    /// This lane's share of `n` items.  Items are split evenly, with the remainder spread one
    /// each over the first `n % count` lanes.
    fn range(lane: Lane, n: usize) Range {
        const c: usize = lane.count;
        const i: usize = lane.index;
        const base = n / c;
        const rem = n % c;
        const start = i * base + @min(i, rem);
        const len = base + @intFromBool(i < rem);
        return .{ .start = start, .end = start + len };
    }

    test range {
        for (1..32) |lane_count| {
            for (0..20) |n_bits| {
                const n: usize = @as(usize, 1) << @intCast(n_bits);

                var lane: Lane = undefined;
                lane.index = 0;
                lane.count = @intCast(lane_count);
                var range_res = lane.range(n);
                var min_len = range_res.len();
                var max_len = range_res.len();
                var end_prev = range_res.end;
                for (1..lane_count) |lane_idx| {
                    lane.index = @intCast(lane_idx);
                    range_res = lane.range(n);

                    // expect: evenly distributed
                    min_len = @min(min_len, range_res.len());
                    max_len = @min(max_len, range_res.len());
                    try std.testing.expect(max_len - min_len < 2);

                    // expect: sequential
                    try std.testing.expectEqual(end_prev, range_res.start);
                    end_prev = range_res.end;
                }
                try std.testing.expectEqual(n, end_prev);
            }
        }
    }

    /// Poison the lane group so every lane blocked in (or later entering) `sync`/`broadcast`
    /// returns `err`.  Intended to be called by whoever owns the lane's body when it fails.
    fn abort(lane: *Lane, io: std.Io, err: anyerror) void {
        if (lane.isSingle()) return;
        lane.barrier.abort(io, err);
    }

    fn sync(lane: *Lane, io: std.Io) anyerror!void {
        // single lane case
        if (lane.isSingle()) return;
        try lane.barrier.wait(io);
    }

    test "Lane.sync" {
        const num_lanes = 4;
        const io = std.testing.io;

        const Shared = struct {
            data: [num_lanes]u32 = @splat(0),
            ok: std.atomic.Value(u32) = .init(0),
        };
        var shared: Shared = .{};
        var barrier: Barrier = .{ .expected = num_lanes };
        var slot: Lane.BroadcastSlot = .{};

        const Worker = struct {
            fn run(s: *Shared, b: *Barrier, slot_: *Lane.BroadcastSlot, io_: std.Io, idx: u32) anyerror!void {
                var lane: Lane = .{
                    .index = idx,
                    .count = num_lanes,
                    .broadcast_slot = slot_,
                    .barrier = b,
                };
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
            f.* = try io.concurrent(Worker.run, .{ &shared, &barrier, &slot, io, @as(u32, @intCast(i)) });
        }
        for (&futures) |*f| try f.await(io);

        try std.testing.expectEqual(@as(u32, num_lanes * num_lanes), shared.ok.load(.monotonic));
    }

    fn broadcast(
        lane: *Lane,
        /// type of data being broadcast
        T: type,
        /// source pointer  on src lane, destination pointer on all other lanes
        broadcast_ptr: *T,
        /// index of the source lane
        source_lane_index: u32,
        io: std.Io,
    ) anyerror!void {
        comptime {
            assert(@sizeOf(T) <= @sizeOf(BroadcastSlot));
        }

        // single lane case
        if (lane.isSingle()) return;

        // copy to broadcast memory on source lane
        const len = @sizeOf(T);
        if (source_lane_index == lane.index) {
            const src: []u8 = std.mem.asBytes(broadcast_ptr);
            const dst: []u8 = lane.broadcast_slot.bytes[0..len];
            assert(src.len == len);
            assert(dst.len == len);
            @memcpy(dst, src);
        }

        try lane.barrier.wait(io);

        // copy from broadcast memory on destination lanes
        if (source_lane_index != lane.index) {
            const src: []u8 = lane.broadcast_slot.bytes[0..len];
            const dst: []u8 = std.mem.asBytes(broadcast_ptr);
            assert(src.len == len);
            assert(dst.len == len);
            @memcpy(dst, src);
        }

        // don't let the source lane reuse broadcast memory until everyone has read it
        try lane.barrier.wait(io);
    }
};

const Barrier = struct {
    /// number of expected waiters
    expected: u32,
    spin_limit: u32 = 256, // chosen by throwing a dart at the wall
    arrived: std.atomic.Value(u32) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    generation: std.atomic.Value(u32) = .init(0),
    /// Set by `abort`.  Sticky.
    aborted: std.atomic.Value(bool) = .init(false),

    const Error = error{aborted};

    fn abort(barrier: *Barrier, io: std.Io) void {
        // TODO: is this the right function to call?
        _ = barrier.aborted.store(true, .release);
        // Change the futex word so a waiter that checked `abort` just before this can't go to sleep.
        _ = barrier.generation.fetchAdd(1, .seq_cst);
        io.futexWake(u32, &barrier.generation.raw, std.math.maxInt(u32));
    }

    fn check(barrier: *Barrier) Error!void {
        if (barrier.aborted.load(.acquire)) return error.aborted;
    }

    fn wait(barrier: *Barrier, io: std.Io) Error!void {
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
                    b.abort(io_);
                    return error.TestAbort;
                }
                try b.wait(io_);
            }
        };

        var futures: [num_lanes]std.Io.Future(anyerror!void) = undefined;
        for (&futures, 0..) |*f, i| {
            f.* = try io.concurrent(Worker.run, .{ &barrier, io, @as(u32, @intCast(i)) });
        }
        // the aborting lane returns its own error; waiters only learn that the barrier was aborted
        try std.testing.expectError(error.TestAbort, futures[0].await(io));
        for (futures[1..]) |*f| try std.testing.expectError(error.aborted, f.await(io));

        // sticky: later waits fail immediately
        try std.testing.expectError(error.aborted, barrier.wait(io));
    }
};

test {
    std.testing.refAllDecls(@This());
}
