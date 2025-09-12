const std = @import("std");
const buf_array_list = @import("buf_array_list");
const juice = @import("utilz.juice");
const Timer = @import("utilz.timer");

const usage =
    \\usage: buf_array_list [options] [arguments]
    \\
    \\options:
    \\  -h, --help      print this help and exit.
    \\
    \\
;

pub fn juicyMain(i: juice.Init(usage)) !void {
    try i.out.print("answer = {}\n", .{buf_array_list.answer()});
}

pub fn main() !void {
    var tim = try Timer.start();
    defer std.log.info("{f}: main", .{tim.read()});
    return juice.main(usage, juicyMain);
}
