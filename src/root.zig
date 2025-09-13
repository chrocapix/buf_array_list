const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

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
        cap_alloc: CapacityAllocated = .{},

        const CapacityAllocated = packed struct {
            allocated: u1 = 0,
            capacity: usizem1 = 0,
        };

        const usizem1 = std.meta.Int(.unsigned, @bitSizeOf(usize) - 1);

        pub const max_capacity = std.math.maxInt(usizem1);

        fn capacity(this: @This()) usize {
            return this.cap_alloc.capacity;
        }

        pub fn initBuffer(buf: Slice) @This() {
            std.debug.assert(buf.len <= max_capacity);
            return .{
                .items = buf[0..0],
                .cap_alloc = .{ .capacity = @intCast(buf.len) },
            };
        }

        pub fn deinit(this: *@This(), al: Allocator) void {
            if (this.cap_alloc.allocated != 0)
                al.free(this.allocatedSlice());
            this.* = undefined;
        }

        pub fn append(this: *@This(), al: Allocator, item: T) !void {
            (try this.addOne(al)).* = item;
        }

        pub fn appendAssumeCapacity(this: *@This(), item: T) void {
            this.addOneAssumeCapacity().* = item;
        }

        pub fn addOneAssumeCapacity(this: *@This()) *T {
            std.debug.assert(this.items.len < this.capacity());

            this.items.len += 1;
            return &this.items[this.items.len - 1];
        }

        pub fn addOne(this: *@This(), al: Allocator) !*T {
            try this.ensureTotalCapacity(al, this.items.len + 1);
            return this.addOneAssumeCapacity();
        }

        pub fn ensureTotalCapacity(
            this: *@This(),
            al: Allocator,
            new_cap: usize,
        ) Allocator.Error!void {
            std.debug.assert(new_cap <= max_capacity);

            if (this.capacity() >= new_cap)
                return;

            return this.ensureTotalCapacityPrecise(
                al,
                growCapacity(this.cap_alloc.capacity, @intCast(new_cap)),
            );
        }

        pub fn ensureTotalCapacityPrecise(
            this: *@This(),
            al: Allocator,
            new_cap: usize,
        ) Allocator.Error!void {
            std.debug.assert(new_cap <= max_capacity);
            if (this.capacity() >= new_cap) return;

            const new_cap1: usizem1 = @intCast(new_cap);

            if (this.cap_alloc.allocated == 0) {
                const new_mem = try al.alignedAlloc(T, alignment, new_cap);
                @memcpy(new_mem[0..this.items.len], this.items);
                this.items.ptr = new_mem.ptr;
                this.cap_alloc.capacity = new_cap1;
                this.cap_alloc.allocated = 1;
                return;
            }

            const old_mem = this.allocatedSlice(); //)this.items.ptr[0..this.cap_alloc.capacity];
            // const old_mem = this.allocatedMemory();
            if (al.remap(old_mem, new_cap)) |new_mem| {
                this.items.ptr = new_mem.ptr;
                this.cap_alloc.capacity = new_cap1;
                this.cap_alloc.allocated = 1;
            } else {
                const new_mem = try al.alignedAlloc(T, alignment, new_cap);
                @memcpy(new_mem[0..this.items.len], this.items);
                al.free(old_mem);
                this.items.ptr = new_mem.ptr;
                this.cap_alloc.capacity = new_cap1;
                this.cap_alloc.allocated = 1;
            }
        }

        fn growCapacity(current: usizem1, minimum: usizem1) usize {
            var new = current;
            while (true) {
                new +|= new / 2 + init_capacity;
                if (new >= minimum)
                    return new;
            }
        }

        pub fn allocatedSlice(this: @This()) Slice {
            return this.items.ptr[0..this.cap_alloc.capacity];
        }
    };
}
