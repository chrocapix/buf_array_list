const std = @import("std");

pub fn answer() usize {
    return 42;
}

test answer {
    try std.testing.expect(answer() == 42);
}
