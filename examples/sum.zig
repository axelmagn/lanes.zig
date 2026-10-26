//! parallel sum

const std = @import("std");
const lanes = @import("lanes");
const log = std.log.scoped(.example);

pub fn main(init: std.process.Init) !void {
    // populate data
    const n = 10_000_000;
    const data = try init.gpa.alloc(u64, n);
    defer init.gpa.free(data);
    for (data, 0..) |*x, i| x.* = i;

    // initialize lanes before using
    lanes.init(init.gpa, init.io);
    defer lanes.deinit();
    const lane_count: u32 = @intCast(try std.Thread.getCpuCount());

    // Run task on every lane and wait for all of them to finish
    try lanes.launch(lane_count, task, .{data});

    std.debug.print("expected = {d}\n", .{@as(u64, n) * (n - 1) / 2});
}

/// This runs once on every lane.
fn task(data: []const u64) !void {
    // set up and broadcast communication buffer for partial sums
    var partials: []u64 = undefined;
    const lane_count: usize = @as(usize, lanes.getCount());
    if (lanes.isLeader()) {
        const arena: *std.heap.ArenaAllocator = try lanes.getArena();
        partials = try arena.allocator().alloc(u64, lane_count);
    }
    try lanes.broadcast([]u64, &partials, lanes.leader_index);
    std.debug.assert(partials.len == lane_count);

    // take this lane's range of data to process
    const my_range = lanes.getRange(data.len);

    // process data in this range
    var sum: u64 = 0;
    for (data[my_range.start..my_range.end]) |x| sum += x;

    // publish the partial sum
    partials[lanes.getIndex()] = sum;

    // synchronize lanes
    try lanes.sync();

    // leader lane combines the results
    if (lanes.isLeader()) {
        var total: u64 = 0;
        for (partials) |p| total += p;
        log.info("{d} lanes, sum = {d}", .{ lanes.getCount(), total });
    }
}
