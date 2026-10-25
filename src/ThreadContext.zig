const std = @import("std");
const Lane = @import("Lane.zig");

const assert = std.debug.assert;

const ThreadContext = @This();

initialized: bool = false,
io: std.Io,
lane: Lane = .single,

/// thread-safe general allocator
safe_gpa: std.mem.Allocator,
/// thread-local scratch arena
arena: std.heap.ArenaAllocator,

const uninitialized: ThreadContext = .{
    .initialized = false,
    .io = undefined,
    .safe_gpa = undefined,
    .arena = undefined,
    .lane = .single,
};

/// set the lane, returning previous lane (for nesting purposes)
fn setLane(tctx: *ThreadContext, lane: Lane) Lane {
    assert(tctx.initialized);
    const prev_lane = tctx.lane;
    tctx.lane = lane;
    return prev_lane;
}
