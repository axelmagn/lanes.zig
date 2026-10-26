//! The context describing how a thread fits into a group. It never makes sense
//! for there to be more lanes than threads.

const std = @import("std");
const Barrier = @import("Barrier.zig");
const assert = std.debug.assert;
const cache_line = std.atomic.cache_line;

const Lane = @This();

pub const Error = Barrier.Error;

index: u32,
count: u32,
/// memory shared by all lanes, used by `broadcast`
broadcast_slot: *BroadcastSlot,
barrier: *Barrier,

pub const single: Lane = .{
    .index = 0,
    .count = 1,
    .broadcast_slot = undefined,
    .barrier = undefined,
};

pub const leader_index = 0;

pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(r: Range) usize {
        return r.end - r.start;
    }
};

pub const BroadcastSlot = struct {
    bytes: [cache_line]u8 align(cache_line) = undefined,
};

pub fn isLeader(lane: Lane) bool {
    return lane.index == leader_index;
}

pub fn isSingle(lane: Lane) bool {
    if (lane.count == 1) {
        assert(lane.index == 0);
        return true;
    }
    return false;
}

/// This lane's share of `n` items.  Items are split evenly, with the remainder spread one
/// each over the first `n % count` lanes.
pub fn range(lane: Lane, n: usize) Range {
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
                max_len = @max(max_len, range_res.len());
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
/// returns `error.aborted`.  Intended to be called by whoever owns the lane's body when it fails.
pub fn abort(lane: Lane, io: std.Io) void {
    if (lane.isSingle()) return;
    lane.barrier.abort(io);
}

pub fn sync(lane: Lane, io: std.Io) Error!void {
    // single lane case
    if (lane.isSingle()) return;
    try lane.barrier.wait(io);
}

test sync {
    const num_lanes = 4;
    const io = std.testing.io;

    var data: [num_lanes]u32 = @splat(0);
    var barrier: Barrier = .{ .expected = num_lanes };
    var slot: BroadcastSlot = .{};

    const Worker = struct {
        fn run(lane: Lane, d: *[num_lanes]u32, io_: std.Io) anyerror!void {
            d[lane.index] = lane.index + 1;
            try lane.sync(io_);
            // after sync, every lane sees every other lane's write
            try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4 }, d);
        }
    };

    var futures: [num_lanes]std.Io.Future(anyerror!void) = undefined;
    for (&futures, 0..) |*f, i| {
        const lane: Lane = .{
            .index = @intCast(i),
            .count = num_lanes,
            .broadcast_slot = &slot,
            .barrier = &barrier,
        };
        f.* = try io.concurrent(Worker.run, .{ lane, &data, io });
    }
    for (&futures) |*f| try f.await(io);
}

pub fn broadcast(
    lane: Lane,
    /// type of data being broadcast
    T: type,
    /// source pointer on src lane, destination pointer on all other lanes
    broadcast_ptr: *T,
    /// index of the source lane
    source_lane_index: usize,
    io: std.Io,
) Error!void {
    comptime {
        assert(@sizeOf(T) <= @sizeOf(BroadcastSlot));
    }

    // single lane case
    if (lane.isSingle()) return;

    // copy to broadcast memory on source lane
    const len = @sizeOf(T);
    if (source_lane_index == @as(usize, lane.index)) {
        const src: []u8 = std.mem.asBytes(broadcast_ptr);
        const dst: []u8 = lane.broadcast_slot.bytes[0..len];
        assert(src.len == len);
        assert(dst.len == len);
        @memcpy(dst, src);
    }

    try lane.barrier.wait(io);

    // copy from broadcast memory on destination lanes
    if (source_lane_index != @as(usize, lane.index)) {
        const src: []u8 = lane.broadcast_slot.bytes[0..len];
        const dst: []u8 = std.mem.asBytes(broadcast_ptr);
        assert(src.len == len);
        assert(dst.len == len);
        @memcpy(dst, src);
    }

    // don't let the source lane reuse broadcast memory until everyone has read it
    try lane.barrier.wait(io);
}

test broadcast {
    const num_lanes = 4;
    const io = std.testing.io;

    var barrier: Barrier = .{ .expected = num_lanes };
    var slot: BroadcastSlot = .{};

    const Worker = struct {
        fn run(lane: Lane, io_: std.Io) anyerror!void {
            // two rounds with different sources, to check the slot can be reused
            for ([_]usize{ 0, num_lanes - 1 }) |source| {
                var value: usize = if (lane.index == source) 100 + source else 0;
                try lane.broadcast(usize, &value, source, io_);
                try std.testing.expectEqual(100 + source, value);
            }
        }
    };

    var futures: [num_lanes]std.Io.Future(anyerror!void) = undefined;
    for (&futures, 0..) |*f, i| {
        const lane: Lane = .{ .index = @intCast(i), .count = num_lanes, .broadcast_slot = &slot, .barrier = &barrier };
        f.* = try io.concurrent(Worker.run, .{ lane, io });
    }
    for (&futures) |*f| try f.await(io);
}
