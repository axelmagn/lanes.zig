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
/// slice of memory shared by all lanes
broadcast_slot: *BroadcastSlot,
barrier: *Barrier,

pub const single: Lane = .{
    .index = 0,
    .count = 1,
    .broadcast_slot = undefined,
    .barrier = undefined,
};

pub const BroadcastSlot = struct {
    bytes: [cache_line]u8 align(cache_line) = undefined,
};

pub fn isLeader(lane: Lane) bool {
    return lane.index == 0;
}

pub fn isSingle(lane: Lane) bool {
    if (lane.count == 1) {
        std.debug.assert(lane.index == 0);
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
pub fn abort(lane: *Lane, io: std.Io) void {
    if (lane.isSingle()) return;
    lane.barrier.abort(io);
}

pub fn sync(lane: *Lane, io: std.Io) Error!void {
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

pub fn broadcast(
    lane: *Lane,
    /// type of data being broadcast
    T: type,
    /// source pointer  on src lane, destination pointer on all other lanes
    broadcast_ptr: *T,
    /// index of the source lane
    source_lane_index: u32,
    io: std.Io,
) Error!void {
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
pub const Range = struct {
    start: usize,
    end: usize,

    pub fn len(r: Range) usize {
        return r.end - r.start;
    }
};
