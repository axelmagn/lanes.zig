const std = @import("std");
const Lane = @import("Lane.zig");

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
