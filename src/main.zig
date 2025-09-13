const std = @import("std");
const Allocator = std.mem.Allocator;
const Sha256 = std.crypto.hash.sha2.Sha256;
const buf_array_list = @import("buf_array_list");
const juice = @import("utilz.juice");
const Timer = @import("utilz.timer");

pub fn sha256(msg: []const u8) [256 / 8]u8 {
    var s: Sha256 = .init(.{});
    s.update(msg);
    return s.finalResult();
}

// const BufArrayList = buf_array_list.Aligned(u8, null);
fn BufArrayList(T: type) type {
    return buf_array_list.Aligned(T, null);
}

const usage =
    \\usage: buf_array_list [options] [arguments]
    \\
    \\options:
    \\  -h, --help        print this help and exit.
    \\      --std         benchmark std.ArrayList
    \\      --buf         benchmark BufArrayList
    \\      --small       benchmark small arrays
    \\  -u=<uint>         bit size of items                
    \\
    \\arguments:
    \\  <uint>          [lo] min size
    \\  <uint>          [hi] max size
    \\  <uint>          [n] data points
    \\
;

fn makeSizes(al: Allocator, lo: usize, hi: usize, m: usize) ![]usize {
    const s = try al.alloc(usize, m + 1);

    const fm: f64 = @floatFromInt(m);
    const flo: f64 = @floatFromInt(lo);
    const fhi: f64 = @floatFromInt(hi);
    for (0..m + 1) |i| {
        const f: f64 = @floatFromInt(i);
        const fs = flo * std.math.pow(f64, fhi / flo, f / fm);
        s[i] = @intFromFloat(@round(fs));
    }
    return s;
}

fn bench(
    out: *std.Io.Writer,
    al: std.mem.Allocator,
    tab: anytype,
    sizes: []usize,
) !void {
    // try tab.ensureTotalCapacityPrecise(al, count);

    var tim: Timer = try .start();
    const times = try al.alloc(f64, sizes.len);
    defer al.free(times);

    var n: usize = 0;
    for (sizes, 0..) |size, is| {
        for (n..size) |i|
            try tab.append(al, @truncate(i));
        n = size;
        times[is] = tim.read().ns;
    }

    var prev: usize = 0;
    for (sizes, times) |size, time| {
        if (size > prev)
            try out.print("{} {}\n", .{ size, time });
        prev = size;
    }
}

fn benchType(out: *std.Io.Writer, al: Allocator, argv: anytype, Item: type, sizes: Sizes) !void {
    const sizeTab = try sizes.make(al, Item);
    defer al.free(sizeTab);

    if (argv.std > 0) {
        var tab: std.ArrayList(Item) = .empty;
        defer tab.deinit(al);
        try bench(out, al, &tab, sizeTab);
    }
    if (argv.buf > 0) {
        var tab: BufArrayList(Item) = .{};
        defer tab.deinit(al);
        try bench(out, al, &tab, sizeTab);
    }
}

fn benchSmall(al: Allocator, argv: anytype, Item: type) !void {
    var size: usize = 12;
    size = size;

    if (argv.std > 0) {
        for (0..argv.n.?) |_| {
            var tab: std.ArrayList(Item) = try .initCapacity(al, 64);
            defer tab.deinit(al);
            asm volatile ("");

            for (0..size) |i|
                try tab.append(al, @intCast(i));

            std.mem.doNotOptimizeAway(tab.items);
        }
    }

    if (argv.buf > 0) {
        for (0..argv.n.?) |_| {
            var buffer: [64]Item = undefined;
            var tab: BufArrayList(Item) = .initBuffer(&buffer);
            defer tab.deinit(al);
            asm volatile ("");

            for (0..size) |i|
                try tab.append(al, @intCast(i));

            std.mem.doNotOptimizeAway(tab.items);
        }
    }
}

const Sizes = struct {
    lo: usize,
    hi: usize,
    count: usize,

    pub fn init(argv: anytype) Sizes {
        return .{
            .lo = argv.lo.?,
            .hi = argv.hi.?,
            .count = argv.n.?,
        };
    }

    pub fn make(this: @This(), al: Allocator, T: type) ![]usize {
        const s = try al.alloc(usize, this.count + 1);

        const tsize: f64 = @floatFromInt(@sizeOf(T));
        const count: f64 = @floatFromInt(this.count);
        const lo: f64 = @floatFromInt(this.lo);
        const hi: f64 = @floatFromInt(this.hi);

        for (0..this.count + 1) |i| {
            const f: f64 = @floatFromInt(i);
            const fs = lo * std.math.pow(f64, hi / lo, f / count) / tsize;
            s[i] = @intFromFloat(@round(fs));
        }
        return s;
    }
};

pub fn juicyMain(i: juice.Init(usage)) !void {
    // const al = std.heap.page_allocator;
    const al = i.gpa;

    // const sizes = try makeSizes(al, i.argv.lo.?, i.argv.hi.?, i.argv.n.?);
    // defer al.free(sizes);

    if (i.argv.small > 0) {
        try benchSmall(al, i.argv, u32);
        return;
    }

    const sizes: Sizes = .init(i.argv);

    const u = i.argv.u orelse 8;

    if (u == 8) try benchType(i.out, al, i.argv, u8, sizes);
    if (u == 16) try benchType(i.out, al, i.argv, u16, sizes);
    if (u == 32) try benchType(i.out, al, i.argv, u32, sizes);
    if (u == 64) try benchType(i.out, al, i.argv, u64, sizes);

    // if (i.argv.std > 0) {
    //     var tab : std.ArrayList(u8) = .empty;
    //     defer tab.deinit(al);
    //     try bench(i.out, al, &tab, sizes);
    // }
    // if (i.argv.buf > 0) {
    //     var tab : BufArrayList(u8) = .{};
    //     defer tab.deinit(al);
    //     try bench(i.out, al, &tab, sizes);
    // }

}

pub fn main() !void {
    // var tim = try Timer.start();
    // defer std.log.info("{f}: main", .{tim.read()});
    return juice.main(usage, juicyMain);
}
