const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const buf_array_list = @import("buf_array_list");
const juice = @import("utilz.juice");
const Timer = @import("utilz.timer");

pub fn sha256(msg: []const u8) [256 / 8]u8 {
    var s: Sha256 = .init(.{});
    s.update(msg);
    return s.finalResult();
}

const BufArrayList = buf_array_list.Aligned(u8, null);

const usage =
    \\usage: buf_array_list [options] [arguments]
    \\
    \\options:
    \\  -h, --help        print this help and exit.
    \\      --std         benchmark std.ArrayList
    \\      --buf         benchmark BufArrayList
    \\
    \\arguments:
    \\  <uint>          [size]
    \\
;

fn bench(
    al: std.mem.Allocator,
    tab: anytype,
    name: []const u8,
    count: usize,
) !void {
    // try tab.ensureTotalCapacityPrecise(al, count);

    var tim: Timer = try .start();
    for (0..count) |i|
        try tab.append(al, @truncate(i));
    // tab.appendAssumeCapacity(@truncate(i));

    // std.mem.doNotOptimizeAway(tab.items);
    std.log.info("{f}: {s}", .{ tim.read().speed(count), name });
    // std.log.info("hash {x}", .{sha256(tab.items)});
}

pub fn juicyMain(i: juice.Init(usage)) !void {
    const size = i.argv.size orelse return error.SizeRequired;
    // const al = std.heap.page_allocator;
    const al = i.gpa;

    if (i.argv.buf > 0) {
        var buffer : [42]u8 = undefined;
        var tab: BufArrayList = .initBuffer(&buffer);
        defer tab.deinit(al);
        try bench(al, &tab, "buf", size);
    }
    if (i.argv.std > 0) {
        var tab: std.ArrayList(u8) = .empty;
        defer tab.deinit(al);
        try bench(al, &tab, "std", size);
    }
}

pub fn main() !void {
    // var tim = try Timer.start();
    // defer std.log.info("{f}: main", .{tim.read()});
    return juice.main(usage, juicyMain);
}
