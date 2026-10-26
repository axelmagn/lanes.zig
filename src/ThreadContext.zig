const std = @import("std");
const Lane = @import("Lane.zig");

const assert = std.debug.assert;

const ThreadContext = @This();

lane: Lane = .single,
io: ?std.Io,
/// thread-safe general allocator
gpa: ?std.mem.Allocator,
/// thread-local scratch arena
arena: ?std.heap.ArenaAllocator,

pub const uninitialized: ThreadContext = .{
    .lane = .single,
    .io = null,
    .gpa = null,
    .arena = null,
};

/// set the lane, returning previous lane (for nesting purposes)
fn setLane(tctx: *ThreadContext, lane: Lane) Lane {
    assert(tctx.initialized);
    const prev_lane = tctx.lane;
    tctx.lane = lane;
    return prev_lane;
}
