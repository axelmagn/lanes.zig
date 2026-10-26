const std = @import("std");
const ThreadContext = @import("ThreadContext.zig");
const Barrier = @import("Barrier.zig");
const Lane = @import("Lane.zig");

const ArgsTuple = std.meta.ArgsTuple;

/// thread local static variable tracking thread state
threadlocal var thread_context: ThreadContext = .uninitialized;

pub const Error = error{
    uninitialized,
    zero_lanes,
} || Lane.Error;

pub fn init(gpa: std.mem.Allocator, io: std.Io) void {
    thread_context = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
}

pub fn deinit() void {
    if (thread_context.arena) |*arena| arena.deinit();
    thread_context = .uninitialized;
}

pub const LaunchError = Error || std.Thread.SpawnError || error{OutOfMemory};

/// launch a function across `lanes` lanes, and wait for all of them to finish.
/// The calling thread runs lane 0; the rest run on new threads.
pub fn launch(
    lanes: u32,
    comptime function: anytype,
    args: ArgsTuple(@TypeOf(function)),
) LaunchError!void {
    comptime if (@typeInfo(@TypeOf(function)).@"fn".return_type.? != void)
        @compileError("launch: function must return void");

    if (lanes == 0) return Error.zero_lanes;

    const arena = try getArena();
    const io = try getIo();
    var barrier: Barrier = .{ .expected = lanes };
    var slot: Lane.BroadcastSlot = .{};
    var lane: Lane = .{
        .index = 0,
        .count = lanes,
        .broadcast_slot = &slot,
        .barrier = &barrier,
    };

    // allocate before any lane runs: lane 0 swaps out thread_context.arena while it executes
    const threads = try arena.allocator().alloc(std.Thread, lanes - 1);

    var spawned: usize = 0;
    // join before barrier and slot leave scope
    defer for (threads[0..spawned]) |t| t.join();
    // if a spawn fails, release lanes already waiting on the barrier
    errdefer barrier.abort(io);

    for (threads, 1..) |*t, i| {
        lane.index = @intCast(i);
        t.* = try std.Thread.spawn(.{}, runOnLane, .{ lane, thread_context, function, args });
        spawned += 1;
    }

    lane.index = 0;
    runOnLane(lane, thread_context, function, args);
}

test launch {
    init(std.testing.allocator, std.testing.io);
    defer deinit();

    const worker = struct {
        fn run(counter: *std.atomic.Value(u32), expected: u32) void {
            _ = counter.fetchAdd(1, .monotonic);
            sync() catch unreachable;
            std.testing.expectEqual(expected, getCount()) catch unreachable;
            std.testing.expectEqual(expected, counter.load(.monotonic)) catch unreachable;
        }
    };

    for ([_]u32{ 1, 4 }) |n| {
        var counter: std.atomic.Value(u32) = .init(0);
        try launch(n, worker.run, .{ &counter, n });
        try std.testing.expectEqual(n, counter.load(.monotonic));
    }

    var counter: std.atomic.Value(u32) = .init(0);
    try std.testing.expectError(Error.zero_lanes, launch(0, worker.run, .{ &counter, 0 }));
}

fn runOnLane(
    lane: Lane,
    parent: ThreadContext,
    function: anytype,
    args: ArgsTuple(@TypeOf(function)),
) void {
    const prev = thread_context;
    defer thread_context = prev;
    thread_context = parent;
    thread_context.lane = lane;
    thread_context.arena = .init(parent.gpa.?);
    defer thread_context.arena.?.deinit();
    @call(.auto, function, args);
}

pub fn sync() anyerror!void {
    try thread_context.lane.sync(try getIo());
}

pub fn broadcast(T: type, broadcast_ptr: *T, source_lane_index: u32) Error!void {
    try thread_context.lane.broadcast(T, broadcast_ptr, source_lane_index, try getIo());
}

/// lane index
pub fn getIndex() u32 {
    return thread_context.lane.index;
}

/// number of lanes in group
pub fn getCount() u32 {
    return thread_context.lane.count;
}

/// is current lane leader
pub fn isLeader() bool {
    return thread_context.lane.isLeader();
}

/// is current lane the only one
pub fn isSingle() bool {
    return thread_context.lane.isSingle();
}

pub fn getIo() Error!std.Io {
    return if (thread_context.io) |io| io else Error.uninitialized;
}

pub fn getGpa() Error!std.mem.Allocator {
    return if (thread_context.gpa) |gpa| gpa else Error.uninitialized;
}

pub fn getArena() Error!*std.heap.ArenaAllocator {
    return if (thread_context.arena == null) Error.uninitialized else &thread_context.arena.?;
}

test {
    _ = std.testing.refAllDecls(@This());
    // refAllDecls only sees pub decls, so reference the private imports explicitly
    _ = Barrier;
    _ = Lane;
}
