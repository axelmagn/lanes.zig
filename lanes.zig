const std = @import("std");
const atomic = std.atomic;
const cache_line = atomic.cache_line;

threadlocal var lane: ?Lane = null;

pub const Lane = struct {
    idx: u32,
    group: *LaneGroup,
    arena: std.heap.ArenaAllocator,

    pub const Memo = struct { idx: u32, group: *LaneGroup };
};

pub const LaneGroup = struct {
    count: u32,
    barrier: Barrier,
    slots: []Slot,
    counter: atomic.Value(usize), // for dynamic ranges
};

pub const Slot = struct {
    bytes: [cache_line]u8 align(cache_line),
};

pub const Barrier = struct {
    count: u32,
    arrived: atomic.Value(u32),
    generation: atomic.value(u32),
};

pub const Range = struct { start: usize, end: usize };
