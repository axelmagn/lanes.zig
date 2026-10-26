# lanes.zig

A Zig parallelism library based on
[Multi-Core by Default](https://www.dgtlgrove.com/p/multi-core-by-default) by
Ryan Fleury.

This library allows the user to write "CPU kernels" and manage them via thread
lanes. CPU kernels resemble GPU kernels in CUDA or shaders: they execute
sequentially on multiple threads, coordinated by synchronization barriers and
broadcasts.

It exposes a simple, opinionated API mediated by thread-local static variables.

Examples can be found in the `examples` directory, and can be built with
`zig build examples`.

## Installation

Fetch the dependency.

```bash
zig fetch --save=lanes git+https://github.com/axelmagn/lanes.zig.git
```

Import the dependency in your code.

```zig
pub fn build(b: *std.Build) void {
    const mod = b.addModule( ... );

    const lanes = b.dependency("lanes", .{});
    mod.addImport("lanes", lanes.module("lanes"));
}
```

## Example: Parallel Sum

This code uses all cores to calculate the sum of a data array.

[Full Example](./examples/sum.zig)

```zig
pub fn main(init: std.process.Init) !void {
    // data: [N]u64 = ...

    // initialize lanes before using
    lanes.init(init.gpa, init.io);
    defer lanes.deinit();
    const lane_count = try std.Thread.getCpuCount();

    // Spawn lane_count - 1 dedicated worker threads
    // Run task on every lane and wait for all of them to finish
    try lanes.launch(lane_count, kernel, .{data});

    /// ...
}

/// This runs once on every lane.
fn kernel(data: []const u64) !void {
    // set up and broadcast communication buffer for partial sums
    var partials: []u64 = undefined;
    const lane_count: usize = lanes.getCount();
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
```

## Versioning

This library is still experimental - expect API changes between minor versions.

`main` branch builds against latest stable zig (0.17 at time of writing).

Latest library versions are tagged with semantic versioning: `v<major>.<minor>`.
Subminor versions are omitted.

When subsequent versions of zig release, the latest version of the library
supporting old versions of zig will be tagged with `zig-<version>`.

## LLM Usage

This code is mostly hand-written. LLM coding agents were used for
troubleshooting, test authoring, and prototyping.
