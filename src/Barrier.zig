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
    const rounds = 1000;
    const io = std.testing.io;

    const Shared = struct {
        barrier: Barrier = .{ .expected = num_lanes },
        counter: std.atomic.Value(u32) = .init(0),
    };
    var shared: Shared = .{};

    const Worker = struct {
        fn run(s: *Shared, io_: std.Io) anyerror!void {
            for (1..rounds + 1) |round| {
                _ = s.counter.fetchAdd(1, .monotonic);
                try s.barrier.wait(io_);
                // every lane has incremented before anyone gets here
                try std.testing.expectEqual(round * num_lanes, s.counter.load(.monotonic));
                // keep fast lanes from incrementing before slow lanes have checked
                try s.barrier.wait(io_);
            }
        }
    };

    var futures: [num_lanes]std.Io.Future(anyerror!void) = undefined;
    for (&futures) |*f| f.* = try io.concurrent(Worker.run, .{ &shared, io });
    for (&futures) |*f| try f.await(io);
}

pub fn abort(barrier: *Barrier, io: std.Io) void {
    _ = barrier.aborted.store(true, .release);
    // Change the futex word so a waiter that checked `abort` just before this can't go to sleep.
    _ = barrier.generation.fetchAdd(1, .seq_cst);
    io.futexWake(u32, &barrier.generation.raw, std.math.maxInt(u32));
}

test abort {
    const io = std.testing.io;

    // one lane short, so the waiters can only be released by abort.
    // spin_limit = 0 forces them down the futex path.
    var barrier: Barrier = .{ .expected = 4, .spin_limit = 0 };

    var futures: [3]std.Io.Future(Error!void) = undefined;
    for (&futures) |*f| f.* = try io.concurrent(wait, .{ &barrier, io });

    barrier.abort(io);
    for (&futures) |*f| try std.testing.expectError(error.aborted, f.await(io));

    // sticky: later waits fail immediately
    try std.testing.expectError(error.aborted, barrier.wait(io));
}
