const std = @import("std");
const lanes = @import("lanes");
const log = std.log.scoped(.example);
const Atomic = std.atomic.Value;

const radix_bits = 8;
const buckets = 1 << radix_bits;
const passes = @bitSizeOf(u64) / radix_bits;

fn task(data: []u64) !void {
    // set up and broadcast shared data
    const Scratch = struct {
        /// ping pong partner of data
        tmp: []u64,
        /// histogram of bucket sizes per lane
        hist: []usize,
    };
    var scratch: Scratch = undefined;
    const lane = lanes.getIndex();
    const lane_count = lanes.getCount();
    if (lanes.isLeader()) {
        const arena = try lanes.getArena();
        scratch = .{
            .tmp = try arena.allocator().alloc(u64, data.len),
            .hist = try arena.allocator().alloc(usize, buckets * lane_count),
        };
    }
    try lanes.broadcast(Scratch, &scratch, lanes.leader_index);

    // scan across bits in chunks
    const range = lanes.getRange(data.len);
    var src = data;
    var dst = scratch.tmp;
    for (0..passes) |pass| {
        // count data in range
        const lane_hist = scratch.hist[lane * buckets ..][0..buckets];
        @memset(lane_hist, 0);
        for (range.start..range.end) |i| {
            const bucket = getBucket(src[i], pass);
            lane_hist[bucket] += 1;
        }
        try lanes.sync();

        // calculate the starting index for each bucket in this lane
        var next_index: [buckets]usize = @splat(0);
        var total: usize = 0;
        for (0..buckets) |b| {
            next_index[b] = total;
            for (0..lane_count) |l| {
                const idx = l * buckets + b;
                const count = scratch.hist[idx];
                total += count;
                if (l < lane) next_index[b] += count;
            }
        }

        // move elements from src to dst
        for (range.start..range.end) |i| {
            const value = src[i];
            const bucket = getBucket(value, pass);
            const idx = next_index[bucket];
            next_index[bucket] += 1;
            dst[idx] = value;
        }
        try lanes.sync();

        // swap src and dst for next round
        std.mem.swap([]u64, &src, &dst);
    }
    // `passes` is even, so the sorted data ended up back in `data`.
    comptime std.debug.assert(passes % 2 == 0);
}

fn getBucket(value: u64, pass: usize) usize {
    const shr = pass * radix_bits;
    const mask = buckets - 1;
    return @intCast((value >> @intCast(shr)) & mask);
}

pub fn main(init: std.process.Init) !void {
    // set up lanes
    const gpa = init.gpa;
    const io = init.io;
    lanes.init(gpa, io);
    defer lanes.deinit();

    // populate data
    const n = 1 << 24;
    const data = try gpa.alloc(u64, n);
    defer gpa.free(data);
    var prng = std.Random.DefaultPrng.init(12345);
    prng.random().bytes(std.mem.sliceAsBytes(data));

    // launch
    const lane_count: u32 = @intCast(try std.Thread.getCpuCount());
    log.info("sorting {d} u64 keys", .{n});
    const start = std.Io.Timestamp.now(io, .awake);
    try lanes.launch(lane_count, task, .{data});
    const end = std.Io.Timestamp.now(io, .awake);

    // check result
    log.info("checking result...", .{});
    var x = data[0];
    for (data[1..]) |y| {
        std.debug.assert(x <= y);
        x = y;
    }
    const ms = start.durationTo(end).toMilliseconds();
    log.info("array successfully sorted in {d}ms", .{ms});
}
