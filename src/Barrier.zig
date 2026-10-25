const std = @import("std");

const Barrier = @This();

/// number of expected waiters
expected: u32,
spin_limit: u32 = 256, // chosen by throwing a dart at the wall
arrived: std.atomic.Value(u32) = .init(0),
sleepers: std.atomic.Value(u32) = .init(0),
generation: std.atomic.Value(u32) = .init(0),
/// Set by `abort`.  Sticky.
aborted: std.atomic.Value(bool) = .init(false),

pub const Error = error{aborted};

pub fn abort(barrier: *Barrier, io: std.Io) void {
    _ = barrier.aborted.store(true, .release);
    // Change the futex word so a waiter that checked `abort` just before this can't go to sleep.
    _ = barrier.generation.fetchAdd(1, .seq_cst);
    io.futexWake(u32, &barrier.generation.raw, std.math.maxInt(u32));
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

pub fn check(barrier: *Barrier) Error!void {
    if (barrier.aborted.load(.acquire)) return error.aborted;
}

pub fn wait(barrier: *Barrier, io: std.Io) Error!void {
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
