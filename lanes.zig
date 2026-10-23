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

const Lane = struct {
    lane_index: u32 = 0,
    lane_count: u32 = 1,
    broadcast_memory: [std.atomic.cache_line]u8,
    barrier: ?*Barrier = null,
    const single: Lane = .{};
};

// threadlocal var current_lane: ?Lane = null;

// pub const Lane = struct {
//     /// lane index in the group
//     index: u32,
//     /// lane group this lane belongs to
//     group: *LaneGroup,
//     /// lane-local arena, guaranteed to not be contended
//     arena: std.heap.ArenaAllocator,
//
//     pub const Memo = struct { idx: u32, group: *LaneGroup };
// };
//
// const LaneGroup = struct {
//     io: std.Io,
//     gpa: std.mem.Allocator,
//
//     /// number of lanes in the group
//     count: u32,
//     barrier: Barrier,
//     slots: []Slot,
//     counter: atomic.Value(usize), // for dynamic ranges
//
// };
//
// const Slot = struct {
//     bytes: [cache_line]u8 align(cache_line),
// };

const Barrier = struct {
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

// // ---- launch ----
// pub fn run(gpa: Allocator, lane_count: ?u32, comptime f: anytype, args: anytype) !void {
//     @panic("TODO");
// }
//     // Spawns count-1 threads; the calling thread is lane 0. f receives *Lane.
//
// // ---- identity ----
// pub fn count(l: *const Lane) u32 {
//     @panic("TODO");
// }
// pub fn isFirst(l: *const Lane) bool {
//     @panic("TODO");
// }
//
// // ---- sync ----
// pub fn sync(l: *Lane) void {
//     @panic("TODO");
// }
//
// // ---- work splitting ----
// pub fn splitRange(n: usize, parts: u32, i: u32) Range   // pure math
// pub fn range(l: *const Lane, n: usize) Range            // static even split
// pub fn dynamic(l: *Lane, n: usize, chunk: usize) DynamicIter  // syncs, then atomic claiming
//     // DynamicIter.next() ?Range
//
// // ---- collectives (values ≤ one cache line) ----
// pub fn broadcast(l: *Lane, comptime T: type, v: T, src: u32) T
// pub fn reduce(l: *Lane, comptime T: type, v: T, comptime op: std.builtin.ReduceOp) T
// pub fn gather(l: *Lane, comptime T: type, v: T, out: []T) void
//
// // ---- memory ----
// pub fn arena(l: *Lane) Allocator
// pub fn gpa(l: *const Lane) Allocator
// pub fn allocShared(l: *Lane, comptime T: type, n: usize) ![]T  // lane 0 allocs, broadcasts
// pub fn freeShared(l: *Lane, comptime T: type, s: []T) void     // sync, then lane 0 frees
// pub fn syncResetArena(l: *Lane) void                           // sync, then reset own arena
//
// // ---- subgroups ----
// pub fn split(l: *Lane, n_groups: u32) !Membership  // switch into a subgroup
// pub fn join(l: *Lane, prev: Membership) void       // restore, sync, lane 0 frees children
//
// pub fn current() *Lane {
//     assert(current_lane != null);
//     return current_lane.?;
// }

test {
    std.testing.refAllDecls(@This());
}
