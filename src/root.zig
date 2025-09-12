const std = @import("std");
const mem = std.mem;
const Al = mem.Allocator;

pub fn Aligned(T: type, alignment: ?mem.Alignment) type {
    if (alignment) |a| {
        if (a.toByteUnits() == @alignOf(T)) {
            return Aligned(T, null);
        }
    }
    const init_capacity = @as(
        comptime_int,
        @max(1, std.atomic.cache_line / @sizeOf(T)),
    );

    return struct {
        const Slice = if (alignment) |a| ([]align(a.toByteUnits()) T) else []T;

        items: Slice = &[_]T{},
        capacity_owned: usize = 0,

        pub const max_capacity = 1 << (@bitSizeOf(usize) - 1);

        fn capacity(this: @This()) usize {
            return (this.capacity_owned << 1) >> 1;
        }

        fn setCapacityOwned(this: *@This(), new_cap: usize) void {
            std.debug.assert(new_cap < max_capacity);
            const owned_bit = 1 << (@bitSizeOf(usize) - 1);
            this.capacity_owned = owned_bit | new_cap;
        }

        fn ownedMask(this: @This()) usize {
            const bits: isize = @bitCast(this.capacity_owned);
            return @bitCast(bits >> 63);
        }

        pub fn initBuffer(buf: Slice) @This() {
            return .{
                .items = buf[0..0],
                .capacity_owned = buf.len,
            };
        }

        pub fn deinit(this: *@This(), al: Al) void {
            // if (this.m.is_owned == 0) return;

            al.free(this.freeableMemory());
            // al.free(this.allocatedSlice());
            this.* = undefined;
        }

        pub fn append(this: *@This(), al: Al, item: T) !void {
            // std.debug.print("append {}..\n", .{item});
            // if (this.items.len >= this.m.capacity)

            // this.items.len += 1;
            // this.items[this.items.len - 1] = item;
            (try this.addOne(al)).* = item;
        }

        pub fn appendAssumeCapacity(this: *@This(), item: T) void {
            // std.debug.print("append {}..\n", .{item});
            // if (this.items.len >= this.m.capacity)
            // try this.ensureTotalCapacity(al, this.items.len + 1);

            this.addOneAssumeCapacity().* = item;
            // this.items.len += 1;
            // this.items[this.items.len - 1] = item;
        }

        pub fn addOneAssumeCapacity(this: *@This()) *T {
            std.debug.assert(this.items.len < this.capacity());

            this.items.len += 1;
            return &this.items[this.items.len - 1];
        }

        pub fn addOne(this: *@This(), al: Al) !*T {
            try this.ensureTotalCapacity(al, this.items.len + 1);
            return this.addOneAssumeCapacity();
        }

        pub fn ensureTotalCapacity(
            this: *@This(),
            al: Al,
            new_cap: usize,
        ) Al.Error!void {
            std.debug.assert(new_cap < max_capacity);
            if (this.capacity() >= new_cap) return;
            return this.ensureTotalCapacityPrecise(
                al,
                growCapacity(this.capacity(), new_cap),
            );
        }

        pub fn ensureTotalCapacityPrecise(
            this: *@This(),
            al: Al,
            new_cap: usize,
        ) Al.Error!void {
            std.debug.assert(new_cap < max_capacity);
            if (this.capacity() >= new_cap) return;

            const old_mem = this.freeableMemory();
            if (al.remap(old_mem, new_cap)) |new_mem| {
                this.items.ptr = new_mem.ptr;
                this.setCapacityOwned(new_cap);
            } else {
                const new_mem = try al.alignedAlloc(T, alignment, new_cap);
                @memcpy(new_mem[0..this.items.len], this.items);
                al.free(old_mem);
                this.items.ptr = new_mem.ptr;
                this.setCapacityOwned(new_cap);
            }
        }

        fn growCapacity(current: usize, minimum: usize) usize {
            const usizem1 = std.meta.Int(.unsigned, @bitSizeOf(usize) - 1);
            var new: usizem1 = @intCast(current);
            while (true) {
                new +|= new / 2 + init_capacity;
                if (new >= minimum) {
                    return new;
                }
            }
        }

        pub fn allocatedSlice(this: @This()) Slice {
            return this.items.ptr[0..this.capacity()];
        }

        inline fn freeableMemory(this: @This()) Slice {
            const cap = this.capacity() & this.ownedMask();
            return this.items.ptr[0..cap];
        }
    };
}
pub fn AlignedPrev2(T: type, alignment: ?mem.Alignment) type {
    if (alignment) |a| {
        if (a.toByteUnits() == @alignOf(T)) {
            return AlignedPrev2(T, null);
        }
    }
    const init_capacity = @as(
        comptime_int,
        @max(1, std.atomic.cache_line / @sizeOf(T)),
    );

    return struct {
        const Slice = if (alignment) |a| ([]align(a.toByteUnits()) T) else []T;

        items: Slice = &[_]T{},
        capacity_owned: usize = 0,

        fn capacity(this: @This()) usize {
            return (this.capacity_owned << 1) >> 1;
        }

        fn setCapacityOwned(this: *@This(), new_cap: usize) void {
            const owned_bit = 1 << (@bitSizeOf(usize) - 1);
            this.capacity_owned = owned_bit | new_cap;
        }

        fn ownedMask(this: @This()) usize {
            const bits: isize = @bitCast(this.capacity_owned);
            return @bitCast(bits >> 63);
        }

        pub fn initBuffer(buf: Slice) @This() {
            return .{
                .items = buf[0..0],
                .capacity_owned = buf.len,
            };
        }

        pub fn deinit(this: *@This(), al: Al) void {
            // if (this.m.is_owned == 0) return;

            al.free(this.freeableMemory());
            // al.free(this.allocatedSlice());
            this.* = undefined;
        }

        pub fn append(this: *@This(), al: Al, item: T) !void {
            // std.debug.print("append {}..\n", .{item});
            // if (this.items.len >= this.m.capacity)
            try this.ensureTotalCapacity(al, this.items.len + 1);

            this.items.len += 1;
            this.items[this.items.len - 1] = item;
        }

        pub fn appendAssumeCapacity(this: *@This(), item: T) void {
            // std.debug.print("append {}..\n", .{item});
            // if (this.items.len >= this.m.capacity)
            // try this.ensureTotalCapacity(al, this.items.len + 1);

            this.items.len += 1;
            this.items[this.items.len - 1] = item;
        }

        pub fn ensureTotalCapacity(
            this: *@This(),
            al: Al,
            new_cap: usize,
        ) Al.Error!void {
            if (this.capacity() >= new_cap) return;
            return this.ensureTotalCapacityPrecise(
                al,
                growCapacity(this.capacity(), new_cap),
            );
        }

        pub fn ensureTotalCapacityPrecise(
            this: *@This(),
            al: Al,
            new_cap: usize,
        ) Al.Error!void {
            if (this.capacity() >= new_cap) return;

            // var old_mem = this.allocatedSlice();
            // old_mem.len = if (this.m.is_owned != 0) old_mem.len else 0;
            const old_mem = this.freeableMemory();
            if (al.remap(old_mem, new_cap)) |new_mem| {
                // std.debug.print(
                //     "successful remap {} -> {}\n",
                //     .{ this.m.capacity, new_cap },
                // );
                this.items.ptr = new_mem.ptr;
                this.setCapacityOwned(new_cap);
            } else {
                // std.debug.print(
                //     "grow dynamic buffer {} -> {}\n",
                //     .{ this.m.capacity, new_cap },
                // );
                const new_mem = try al.alignedAlloc(T, alignment, new_cap);
                @memcpy(new_mem[0..this.items.len], this.items);
                al.free(old_mem);
                this.items.ptr = new_mem.ptr;
                this.setCapacityOwned(new_cap);
            }
        }

        fn growCapacity(current: usize, minimum: usize) usize {
            var new = current;
            while (true) {
                new +|= new / 2 + init_capacity;
                if (new >= minimum)
                    return new;
            }
        }

        pub fn allocatedSlice(this: @This()) Slice {
            return this.items.ptr[0..this.capacity()];
        }

        inline fn freeableMemory(this: @This()) Slice {
            const cap = this.capacity() & this.ownedMask();
            return this.items.ptr[0..cap];
        }
    };
}

pub fn AlignedPrev(T: type, alignment: ?mem.Alignment) type {
    if (alignment) |a| {
        if (a.toByteUnits() == @alignOf(T)) {
            return AlignedPrev(T, null);
        }
    }
    const init_capacity = @as(
        comptime_int,
        @max(1, std.atomic.cache_line / @sizeOf(T)),
    );
    // const Memory = struct {
    //     capacity: usize = 0,
    //     is_owned: u1 = 0,
    // };
    const bits = @typeInfo(usize).int.bits;
    const Capacity = std.meta.Int(.unsigned, bits - 1);
    const Memory = packed struct {
        capacity: Capacity = 0,
        is_owned: u1 = 0,
    };
    comptime {
        std.debug.assert(@sizeOf(Memory) == @sizeOf(usize));
    }

    return struct {
        const Slice = if (alignment) |a| ([]align(a.toByteUnits()) T) else []T;

        items: Slice = &[_]T{},
        m: Memory = .{},

        pub fn initBuffer(buf: Slice) @This() {
            return .{
                .items = buf[0..0],
                .m = .{
                    .capacity = @intCast(buf.len),
                    .is_owned = 0,
                },
            };
        }

        pub fn deinit(this: *@This(), al: Al) void {
            // if (this.m.is_owned == 0) return;

            al.free(this.freeableMemory());
            // al.free(this.allocatedSlice());
            this.* = undefined;
        }

        pub fn append(this: *@This(), al: Al, item: T) !void {
            // std.debug.print("append {}..\n", .{item});
            // if (this.items.len >= this.m.capacity)
            try this.ensureTotalCapacity(al, this.items.len + 1);

            this.items.len += 1;
            this.items[this.items.len - 1] = item;
        }

        pub fn appendAssumeCapacity(this: *@This(), item: T) void {
            // std.debug.print("append {}..\n", .{item});
            // if (this.items.len >= this.m.capacity)
            // try this.ensureTotalCapacity(al, this.items.len + 1);

            this.items.len += 1;
            this.items[this.items.len - 1] = item;
        }

        pub fn ensureTotalCapacity(
            this: *@This(),
            al: Al,
            new_cap: usize,
        ) Al.Error!void {
            if (this.m.capacity >= new_cap) return;
            return this.ensureTotalCapacityPrecise(
                al,
                growCapacity(this.m.capacity, new_cap),
            );
        }

        pub fn ensureTotalCapacityPrecise(
            this: *@This(),
            al: Al,
            new_cap: usize,
        ) Al.Error!void {
            if (this.m.capacity >= new_cap) return;

            // var old_mem = this.allocatedSlice();
            // old_mem.len = if (this.m.is_owned != 0) old_mem.len else 0;
            const old_mem = this.freeableMemory();
            if (al.remap(old_mem, new_cap)) |new_mem| {
                // std.debug.print(
                //     "successful remap {} -> {}\n",
                //     .{ this.m.capacity, new_cap },
                // );
                this.items.ptr = new_mem.ptr;
                this.m.capacity = @intCast(new_cap);
            } else {
                // std.debug.print(
                //     "grow dynamic buffer {} -> {}\n",
                //     .{ this.m.capacity, new_cap },
                // );
                const new_mem = try al.alignedAlloc(T, alignment, new_cap);
                @memcpy(new_mem[0..this.items.len], this.items);
                al.free(old_mem);
                this.items.ptr = new_mem.ptr;
                this.m.capacity = @intCast(new_cap);
                this.m.is_owned = 1;
            }
        }

        fn growCapacity(current: usize, minimum: usize) usize {
            var new = current;
            while (true) {
                new +|= new / 2 + init_capacity;
                if (new >= minimum)
                    return new;
            }
        }

        pub fn allocatedSlice(this: @This()) Slice {
            return this.items.ptr[0..this.m.capacity];
        }

        fn freeableMemory(this: @This()) Slice {
            return this.items.ptr[0..if (this.m.is_owned != 0) this.m.capacity else 0];
        }
    };
}

pub fn answer() usize {
    return 42;
}

test answer {
    try std.testing.expect(answer() == 42);
}
