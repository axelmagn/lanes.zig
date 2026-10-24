const std = @import("std");

threadlocal var thread_context_local: ?*ThreadContext = null;

pub const ThreadContext = struct {
    io: std.Io,
    scratch: std.heap.ArenaAllocator,
    lane: Lane = .single,

    pub fn init(gpa: std.mem.Allocator) !*ThreadContext {
        const arena = std.heap.ArenaAllocator.init(gpa);
        const tctx = try arena.allocator().create(ThreadContext);
        tctx.* = .{ .arena = arena };
        return tctx;
    }

    pub fn release(tctx: *ThreadContext) void {
        tctx.arena.reset(.free_all);
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

    pub fn sync(lane: *Lane, io: std.Io) void {
        // single lane case
        if (lane == .single) return;
        lane.grouped.barrier.?.wait(io);
    }

    pub fn broadcastSync(
        lane: *Lane,
        /// type of data being broadcast
        T: type,
        /// source pointer  on src lane, destination pointer on all other lanes
        broadcast_ptr: *T,
        /// index of the source lane
        src_lane_idx: u32,
        io: std.Io,
    ) void {
        comptime {
            std.debug.assert(@sizeOf(T) <= std.atomic.cache_line);
        }

        // single lane case
        if (lane == .single) return;

        // copy to broadcast memory on source lane
        const len = @sizeOf(T);
        if (src_lane_idx == lane.grouped.index) {
            const src: []u8 = std.mem.asBytes(broadcast_ptr);
            const dst: []u8 = lane.grouped.broadcast_memory[0..len];
            std.debug.assert(src.len == len);
            std.debug.assert(dst.len == len);
            @memcpy(dst, src);
        }

        lane.grouped.barrier.?.wait(io);

        // copy from broadcast memory on destination lanes
        if (src_lane_idx != lane.index) {
            const src: []u8 = lane.grouped.broadcast_memory[0..len];
            const dst: []u8 = std.mem.asBytes(broadcast_ptr);
            std.debug.assert(src.len == len);
            std.debug.assert(dst.len == len);
            @memcpy(src, dst);
        }
    }

    pub inline fn assertValid(lane: *Lane) void {
        if (lane == .single) return;
        std.debug.assert(lane.grouped.index < lane.grouped.count);
    }
};

const Barrier = struct {
    /// number of expected waiters
    expected: u32,
    spin_limit: u32 = 256, // chosen by throwing a dart at the wall
    arrived: std.atomic.Value(u32) = .init(0),
    sleepers: std.atomic.Value(u32) = .init(0),
    generation: std.atomic.value(u32) = .init(0),

    fn wait(barrier: *Barrier, io: std.Io) void {
        // load generation before arriving
        const gen = barrier.generation.load(.monotonic);

        if (barrier.arrived.fetchAdd(1, .acq_rel) + 1 == barrier.expected) {
            // last arriver.  reset, release, and wake
            barrier.arrived.store(0, .monotonic);
            barrier.generation.store(gen +% 1, .seq_cst);
            if (barrier.sleepers.load(.seq_cst) != 0) {
                io.futexWake(&barrier.generation, std.math.maxInt(u32));
            }
            return;
        }

        // try spinning first
        var spins: u32 = 0;
        while (spins < barrier.spin_limit) : (spins += 1) {
            if (barrier.generation.load(.acquire) != gen) return;
            std.atomic.spinLoopHint();
        }

        // otherwise sleep
        _ = barrier.sleepers.fetchAdd(1, .seq_cst);
        while (barrier.generation.load(.seq_cst) == gen) {
            io.futexWaitUncancelable(&barrier.generation, gen);
        }
        _ = barrier.sleepers.fetchSub(1, .monotonic);
    }

    test wait {
        const num_lanes = 4;
        const rounds = 10_000;
        const spin_limit = 256;
        const io = std.testing.io;

        const Shared = struct {
            barrier: Barrier,
            data: [2][num_lanes]u32 = @splat(@splat(0)),
            success: std.atomic.Value(bool) = .init(false),
        };
        var shared: Shared = .{ .barrier = .{ .count = num_lanes, .spin_limit = spin_limit } };

        const Worker = struct {
            fn run(s: *Shared, io_: std.Io, idx: u32, rounds_: u32) void {
                // Start at 1 so the zero-initialized buffers can never pass by accident.
                var round: u32 = 1;
                while (round <= rounds_) : (round += 1) {
                    const buf = &s.data[round & 1];
                    buf[idx] = round; // plain write, published only by the barrier
                    s.barrier.wait(io_);
                    for (buf) |v| {
                        if (v == round) s.success.store(true, .monotonic);
                    }
                }
            }
        };

        var futures: [num_lanes]std.Io.Future(void) = undefined;
        for (&futures, 0..) |*f, i| {
            f.* = try io.concurrent(Worker.run, .{ &shared, io, @as(u32, @intCast(i)), rounds });
        }
        for (&futures) |*f| f.await(io);

        try std.testing.expect(shared.success.load(.monotonic));
        try std.testing.expectEqual(rounds, shared.barrier.generation.load(.monotonic));
        try std.testing.expectEqual(@as(u32, 0), shared.barrier.arrived.load(.monotonic));
    }
};

pub const Range = struct { start: usize, end: usize };

pub const Error = error{
    uninitialized,
};

test {
    std.testing.refAllDecls(@This());
}
