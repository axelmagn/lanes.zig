//! This example demonstrates the usage of a task queue with uneven workloads
//! by calculating the length of the collatz sequence for each number in a
//! buffer of data.
//!
//! the collatz conjecture states that for any given number, if you follow the
//! process:
//!
//! 1. if the number is even, x = x / 2
//! 2. if the number is odd, x = 3 * x + 1
//!
//! The result will always converge on 1.
//!
//! This program takes a list of numbers, and calculates how many iterations of
//! the above process it takes for them to reach 1.
//!
//! This number varies wildly from number to number, leading to an uneven
//! workload. The solution is intentionally naive so as to demonstrate the task
//! queue.

const std = @import("std");
const lanes = @import("lanes");
const log = std.log.scoped(.example);
const Atomic = std.atomic.Value;
const cache_line = std.atomic.cache_line;

const n = 1 << 24;
const max_iter = 1 << 32;
const chunk_size = 4096;

pub fn main(init: std.process.Init) !void {
    // populate data
    const data = try init.gpa.alloc(u64, n);
    defer init.gpa.free(data);
    for (data, 1..) |*x, i| x.* = i;

    // initialize lanes before using
    lanes.init(init.gpa, init.io);
    defer lanes.deinit();
    const lane_count: u32 = @intCast(try std.Thread.getCpuCount());

    log.info("calculating collatz steps with evenly distributed tasks (slower)", .{});
    var start = std.Io.Timestamp.now(init.io, .awake);
    try lanes.launch(lane_count, evenKernel, .{data});
    var end = std.Io.Timestamp.now(init.io, .awake);
    var ms = start.durationTo(end).toMilliseconds();
    log.info("elapsed: {d}ms", .{ms});

    // reinitialize data
    for (data, 1..) |*x, i| x.* = i;

    log.info("calculating collatz steps with task queue (faster)", .{});
    start = std.Io.Timestamp.now(init.io, .awake);
    try lanes.launch(lane_count, taskKernel, .{data});
    end = std.Io.Timestamp.now(init.io, .awake);
    ms = start.durationTo(end).toMilliseconds();
    log.info("elapsed: {d}ms", .{ms});
}

// calculate collatz steps using tasks
fn taskKernel(data: []u64) !void {
    // leader sets up shared atomic task cursor
    const Shared = struct {
        next_task: *Atomic(usize),
        checksum_partial: []u64,
    };
    var shared: Shared = undefined;
    const arena = try lanes.getArena();
    const lane_count = lanes.getCount();
    if (lanes.isLeader()) {
        shared.next_task = try arena.allocator().create(Atomic(usize));
        shared.next_task.* = .init(0);
        shared.checksum_partial = try arena.allocator().alloc(u64, lane_count);
        @memset(shared.checksum_partial, 0);
    }
    try lanes.broadcast(Shared, &shared, lanes.leader_index);

    // calculate collatz iteration steps for each number.  Store it back in the array
    const lane_idx = lanes.getIndex();
    var checksum_partial: u64 = 0;
    for (0..max_iter) |_| {
        const chunk_idx = shared.next_task.fetchAdd(chunk_size, .acq_rel);
        if (chunk_idx >= data.len) break;
        const chunk_end = @min(chunk_idx + chunk_size, data.len);
        for (chunk_idx..chunk_end) |data_idx| {
            var value = data[data_idx];
            var steps: u64 = 0;
            for (0..max_iter) |_| {
                if (value == 1) break;
                value = if (value % 2 == 0) value / 2 else 3 * value + 1;
                steps += 1;
            }
            std.debug.assert(value == 1);
            data[data_idx] = steps;
            checksum_partial ^= steps;
        }
    }
    shared.checksum_partial[lane_idx] = checksum_partial;
    try lanes.sync();

    // leader combines checksums
    if (lanes.isLeader()) {
        var checksum: u64 = 0;
        for (shared.checksum_partial) |x| {
            checksum ^= x;
        }
        log.info("  checksum: 0x{x}", .{checksum});
    }
}

// calculate collatz steps using even distribution
fn evenKernel(data: []u64) !void {
    // leader sets up shared partials
    const Shared = struct {
        checksum_partial: []u64,
    };
    var shared: Shared = undefined;
    const arena = try lanes.getArena();
    const lane_count = lanes.getCount();
    if (lanes.isLeader()) {
        shared.checksum_partial = try arena.allocator().alloc(u64, lane_count);
        @memset(shared.checksum_partial, 0);
    }
    try lanes.broadcast(Shared, &shared, lanes.leader_index);

    // calculate collatz iteration steps for each number.  Store it back in the array
    const range = lanes.getRange(data.len);
    const lane_idx = lanes.getIndex();
    for (range.start..range.end) |data_idx| {
        var value = data[data_idx];
        var steps: u64 = 0;
        for (0..max_iter) |_| {
            if (value == 1) break;
            value = if (value % 2 == 0) value / 2 else 3 * value + 1;
            steps += 1;
        }
        std.debug.assert(value == 1);
        data[data_idx] = steps;
        shared.checksum_partial[lane_idx] ^= steps;
    }
    try lanes.sync();

    // leader combines checksums
    if (lanes.isLeader()) {
        var checksum: u64 = 0;
        for (shared.checksum_partial) |x| {
            checksum ^= x;
        }
        log.info("  checksum: 0x{x}", .{checksum});
    }
}
