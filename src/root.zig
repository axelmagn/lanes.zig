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
} || Barrier.Error || std.Thread.CpuCountError;

pub const LaunchOptions = struct {
    lanes: LanesMode = .cpus,

    pub const LanesMode = union(enum) {
        cpus,
        exact: u32,
    };
};

pub fn init(safe_gpa: std.mem.Allocator, threaded_io: *std.Io.Threaded) void {
    const arena = std.heap.ArenaAllocator.init(safe_gpa);
    thread_context = .{
        .initialized = true,
        .safe_gpa = safe_gpa,
        .io = threaded_io.io(),
        .arena = arena,
    };
}

pub fn launch(
    function: anytype,
    args: ArgsTuple(@TypeOf(function)),
    opts: LaunchOptions,
) LaunchReturn(@TypeOf(function)) {
    const lanes = switch (opts.lanes) {
        .exact => |n| n,
        .cpus => try std.Thread.getCpuCount(),
    };
    if (lanes == 0) return Error.zero_lanes;

    const barrier: Barrier = .{ .expected = lanes };
    const slot: Lane.BroadcastSlot = .{};

    var futures: [lanes - 1]std.Io.Future(anyerror!void) = undefined;
    var lane: Lane = .{
        .index = undefined,
        .count = lanes,
        .broadcast_slot = &slot,
        .barrier = &barrier,
    };
    const io = try getIo();
    for (&futures, 1..) |*f, i| {
        lane.index = @intCast(i);
        f.* = try io.concurrent(runOnLane, .{ lane, function, args });
    }
    lane.index = 0;
    runOnLane(lane, function, args);
    for (&futures) |*f| try f.await(io);
}

fn LaunchReturn(T: type) type {
    return @typeInfo(T).@"fn".return_type.?;
}

fn runOnLane(
    lane: Lane,
    function: anytype,
    args: ArgsTuple(@TypeOf(function)),
) RunReturn(@TypeOf(function)) {
    const prev_lane = thread_context.lane;
    defer thread_context.lane = prev_lane;
    thread_context.lane = lane;
    return @call(.auto, function, args);
}

fn RunReturn(T: type) type {
    return @typeInfo(T).@"fn".return_type.?;
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
    try expectInitialized();
    return thread_context.io;
}

pub fn getGpa() Error!std.mem.Allocator {
    try expectInitialized();
    return thread_context.safe_gpa;
}

pub fn getScratch() Error!*std.heap.ArenaAllocator {
    try expectInitialized();
    return &thread_context.arena;
}

fn expectInitialized() Error!void {
    if (!thread_context.initialized) return Error.uninitialized;
}
