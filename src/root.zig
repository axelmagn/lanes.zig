const std = @import("std");
const ThreadContext = @import("ThreadContext.zig");
const Barrier = @import("Barrier.zig");
const Lane = @import("Lane.zig");

const ArgsTuple = std.meta.ArgsTuple;

/// thread local static variable tracking thread state
threadlocal var thread_context: ThreadContext = .uninitialized;

pub const leader_index = Lane.leader_index;

/// returned by anything that needs the thread's context when `init` hasn't been called
pub const Error = error{uninitialized};

/// returned by the operations that coordinate lanes
pub const SyncError = Error || Lane.Error;

pub const Range = Lane.Range;

/// Sets up the calling thread's context with `gpa` and `io`; must precede `launch`.
/// Pair with `deinit`.
pub fn init(gpa: std.mem.Allocator, io: std.Io) void {
    thread_context = .{ .gpa = gpa, .io = io, .arena = .init(gpa) };
}

/// Frees the calling thread's arena and returns its context to the uninitialized state.
pub fn deinit() void {
    if (thread_context.arena) |*arena| arena.deinit();
    thread_context = .uninitialized;
}

pub const LaunchError = Error || std.Thread.SpawnError || error{ OutOfMemory, zero_lanes };

/// The error set of a lane function: empty for `void`, otherwise that of its `E!void` return type.
fn FnErrorSet(comptime F: type) type {
    const ret = @typeInfo(F).@"fn".return_type.?;
    return switch (@typeInfo(ret)) {
        .void => error{},
        .error_union => |eu| if (eu.payload == void)
            eu.error_set
        else
            @compileError("launch: function must return void or an error union with a void payload"),
        else => @compileError("launch: function must return void or an error union with a void payload"),
    };
}

/// Runs `function` on `lane_count` lanes (the caller is lane 0) and waits for all to finish.
/// If a lane fails, the others are aborted and the first error raised is returned.
pub fn launch(
    lane_count: usize,
    comptime function: anytype,
    args: ArgsTuple(@TypeOf(function)),
) (LaunchError || FnErrorSet(@TypeOf(function)))!void {
    if (lane_count == 0) return error.zero_lanes;

    const arena = try getArena();
    const io = try getIo();
    var barrier: Barrier = .{ .expected = @intCast(lane_count) };
    var slot: Lane.BroadcastSlot = .{};
    // first error raised by any lane, as an `@intFromError` code.  0 means none.
    var first_err: std.atomic.Value(u16) = .init(0);
    var lane: Lane = .{
        .index = 0,
        .count = @intCast(lane_count),
        .broadcast_slot = &slot,
        .barrier = &barrier,
    };

    // allocate before any lane runs: lane 0 swaps out thread_context.arena while it executes
    const threads = try arena.allocator().alloc(std.Thread, lane_count - 1);

    {
        var spawned: usize = 0;
        // join before barrier, slot and first_err leave scope
        defer for (threads[0..spawned]) |t| t.join();
        // if a spawn fails, release lanes already waiting on the barrier
        errdefer barrier.abort(io);

        for (threads, 1..) |*t, i| {
            lane.index = @intCast(i);
            t.* = try std.Thread.spawn(.{}, runOnLane, .{ lane, thread_context, &first_err, function, args });
            spawned += 1;
        }

        lane.index = 0;
        runOnLane(lane, thread_context, &first_err, function, args);
    }

    // every lane has finished, so this is the root cause rather than a follow-on `aborted`
    const code = first_err.load(.acquire);
    if (code != 0) return @errorCast(@errorFromInt(code));
}

test launch {
    init(std.testing.allocator, std.testing.io);
    defer deinit();

    const worker = struct {
        fn run(counter: *std.atomic.Value(u32), expected: u32) !void {
            _ = counter.fetchAdd(1, .monotonic);
            try sync();
            try std.testing.expectEqual(expected, getCount());
            try std.testing.expectEqual(expected, counter.load(.monotonic));
        }
    };

    for ([_]u32{ 1, 4 }) |n| {
        var counter: std.atomic.Value(u32) = .init(0);
        try launch(n, worker.run, .{ &counter, n });
        try std.testing.expectEqual(n, counter.load(.monotonic));
    }

    var counter: std.atomic.Value(u32) = .init(0);
    try std.testing.expectError(error.zero_lanes, launch(0, worker.run, .{ &counter, 0 }));
}

/// thread-local entrypoint for running a function on a lane
fn runOnLane(
    lane: Lane,
    parent: ThreadContext,
    first_err: *std.atomic.Value(u16),
    function: anytype,
    args: ArgsTuple(@TypeOf(function)),
) void {
    const prev = thread_context;
    defer thread_context = prev;
    thread_context = parent;
    thread_context.lane = lane;
    thread_context.arena = .init(parent.gpa.?);
    defer thread_context.arena.?.deinit();

    const return_type = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const can_fail = @typeInfo(return_type) == .error_union;

    // a `void` function has nothing to report
    if (!can_fail) return @call(.auto, function, args);

    @call(.auto, function, args) catch |err| {
        const io = parent.io.?;

        // Record before aborting: the abort makes the other lanes fail with `error.aborted`,
        // and that must not get in ahead of the error that caused it.  Only the first
        // error is kept; a lane that loses the race has nothing more to do with its error.
        const no_error = 0;
        _ = first_err.cmpxchgStrong(no_error, @intFromError(err), .acq_rel, .acquire);

        // release the lanes still waiting on this one
        lane.abort(io);
    };
}

/// Makes every other lane's pending or future `sync`/`broadcast` return `error.aborted`.
/// Does nothing if the thread has no context.
pub fn abort() void {
    // we can fail silently here: if there's no thread IO, there's no barrier
    // and no sync
    const io = thread_context.io orelse return;
    thread_context.lane.abort(io);
}

test abort {
    init(std.testing.allocator, std.testing.io);
    defer deinit();

    const worker = struct {
        fn run() SyncError!void {
            // the leader gives up; everyone else would wait on it forever
            if (isLeader()) return abort();
            try sync();
        }
    };

    try std.testing.expectError(error.aborted, launch(4, worker.run, .{}));
}

/// Blocks until every lane in the group has reached this call; all lanes must call it.
/// Returns `error.aborted` if the group was aborted.
pub fn sync() SyncError!void {
    try thread_context.lane.sync(try getIo());
}

/// Copies `*broadcast_ptr` from lane `source_lane_index` into the same pointer on all other lanes.
/// Collective: every lane must call it, and `T` must fit in one cache line.
pub fn broadcast(T: type, broadcast_ptr: *T, source_lane_index: usize) SyncError!void {
    try thread_context.lane.broadcast(T, broadcast_ptr, source_lane_index, try getIo());
}

/// this lane's share of `n` items, split evenly across the lanes in the group
pub fn getRange(n: usize) Range {
    return thread_context.lane.range(n);
}

test getRange {
    init(std.testing.allocator, std.testing.io);
    defer deinit();

    const n = 1003;
    const worker = struct {
        fn run(ranges: []Range) void {
            ranges[getIndex()] = getRange(n);
        }
    };

    var ranges: [7]Range = undefined;
    try launch(ranges.len, worker.run, .{&ranges});

    // together the lanes cover 0..n exactly, in order
    var next: usize = 0;
    for (ranges) |r| {
        try std.testing.expectEqual(next, r.start);
        next = r.end;
    }
    try std.testing.expectEqual(n, next);
}

/// lane index
pub fn getIndex() usize {
    return @intCast(thread_context.lane.index);
}

/// number of lanes in group
pub fn getCount() usize {
    return @intCast(thread_context.lane.count);
}

/// is current lane leader
pub fn isLeader() bool {
    return thread_context.lane.isLeader();
}

/// is current lane the only one
pub fn isSingle() bool {
    return thread_context.lane.isSingle();
}

/// the IO associated with this thread
pub fn getIo() Error!std.Io {
    return if (thread_context.io) |io| io else Error.uninitialized;
}

/// the general purpose allocator associated with this thread
pub fn getGpa() Error!std.mem.Allocator {
    return if (thread_context.gpa) |gpa| gpa else Error.uninitialized;
}

/// threadlocal scratch arena
pub fn getArena() Error!*std.heap.ArenaAllocator {
    return if (thread_context.arena == null) Error.uninitialized else &thread_context.arena.?;
}

test {
    std.testing.refAllDecls(@This());
    // refAllDecls only sees pub decls, so reference the private imports explicitly
    _ = Barrier;
    _ = Lane;
}
