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

pub const LaunchOptions = struct {
    lanes: LanesMode = .max_cpus,

    // TODO: more granular modes for performance cores, etc
    pub const LanesMode = union(enum) {
        max_cpus,
        exact: u32,
        up_to: u32,
    };
};

pub fn init(safe_gpa: std.mem.Allocator, threaded_io: *std.Io.Threaded) void {
    const arena = std.heap.ArenaAllocator.init(safe_gpa);
    thread_context = .{
        .safe_gpa = safe_gpa,
        .io = threaded_io.io(),
        .arena = arena,
    };
}

/// launch a function across multiple lanes.
/// Returns a slice containing function results for each lane, allocated from thread arena.
pub fn launch(
    comptime function: anytype,
    args: ArgsTuple(@TypeOf(function)),
    opts: LaunchOptions,
) LaunchError(function)![]FuncReturn(function) {
    // I wish there was a better way to inspect CPUs and get just the performance ones
    const lanes = switch (opts.lanes) {
        .exact => |n| n,
        .max_cpus => try std.Thread.getCpuCount(),
        .up_to => |n| @min(n, try std.Thread.getCpuCount()),
    };
    if (lanes == 0) return Error.zero_lanes;
    const barrier: Barrier = .{ .expected = lanes };
    const slot: Lane.BroadcastSlot = .{};

    const arena = try getArena();
    const results = try arena.allocator().alloc(FuncReturn(function), lanes);
    const Future = std.Io.Future(FuncReturn(function));
    var futures: []Future = try arena.allocator().alloc(Future, lanes - 1);
    defer arena.allocator().free(futures);

    var lane: Lane = .{
        .index = undefined,
        .count = lanes,
        .broadcast_slot = &slot,
        .barrier = &barrier,
    };
    const io = try getIo();
    var concurrent_err: ?std.Io.ConcurrentError = null;
    var failed_idx: usize = 0;
    for (&futures, 1..) |*f, i| {
        lane.index = @intCast(i);
        f.* = io.concurrent(runOnLane, .{ function, args, lane, thread_context }) catch |err| {
            concurrent_err = err;
            failed_idx = i;
            break;
        };
    }

    if (concurrent_err != null) {
        for (futures, 0..failed_idx) |f, _| {
            f.cancel(io);
        }

    }

    lane.index = 0;
    results[0] = runOnLane(function, args, lane, thread_context);
    for (&futures, 1..) |f, i| {
        results[i] = f.await(io);
    }
    for (results) |res| {
        // if there was an error, there will be some superfluous aborts.
        // Return the first error that is not an abort.
        res catch |err| switch (err) {
            Error.aborted => {},
            else => return err,
        };
    }
    return results;
}

pub fn LaunchError(comptime function: anytype) type {
    return Error ||
        FuncErrors(function) ||
        std.Thread.CpuCountError ||
        std.Io.ConcurrentError ||
        error{OutOfMemory};
}

fn FuncErrors(comptime function: anytype) type {
    const f_return = @typeInfo(@TypeOf(function)).@"fn".return_type.?;
    const f_return_info = @typeInfo(f_return);
    return switch (f_return_info) {
        .error_set => |es| es,
        .error_union => |eu| eu.error_set,
        else => error{},
    };
}

fn FuncReturn(comptime function: anytype) type {
    return @typeInfo(@TypeOf(function)).@"fn".return_type.?;
}

pub fn runOnLane(
    comptime function: anytype,
    args: ArgsTuple(@TypeOf(function)),
    lane: Lane,
    src_thread_context: ThreadContext,
) FuncReturn(function) {
    try expectInitialized(src_thread_context);
    const prev_tctx = thread_context;
    defer thread_context = prev_tctx;
    thread_context = src_thread_context;
    thread_context.arena = std.heap.ArenaAllocator(try getGpa());
    defer thread_context.arena.deinit();
    thread_context.lane = lane;
    return @call(.auto, function, args);
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
    return if (thread_context.safe_gpa) |gpa| gpa else Error.uninitialized;
}

pub fn getArena() Error!*std.heap.ArenaAllocator {
    return if (thread_context.arena == null) Error.uninitialized else &thread_context.arena.?;
}

fn expectInitialized(tctx: ThreadContext) Error!void {
    if (!tctx.initialized) return Error.uninitialized;
}

test {
    _ = std.testing.refAllDecls(@This());
    // refAllDecls only sees pub decls, so reference the private imports explicitly
    _ = Barrier;
    _ = Lane;
}
