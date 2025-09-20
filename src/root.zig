const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;

pub fn ArrayList(T: type) type {
    return Aligned(T, null);
}

/// A contiguous, growable list of arbitrarily aligned items in memory.
/// This is a wrapper around an array of T values aligned to `alignment`-byte
/// addresses. If the specified alignment is `null`, then `@alignOf(T)` is used.
///
/// Functions that potentially allocate memory accept an `Allocator` parameter.
/// Initialize with `empty`, `initBuffer` or `initCapacity`, and deinitialize
/// with `deinit` or use `toOwnedSlice`.
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
        const This = @This();

        const Slice = if (alignment) |a| ([]align(a.toByteUnits()) T) else []T;

        /// Contents of the list. This field is intended to be accessed
        /// directly.
        ///
        /// Pointers to elements in this slice are invalidated by various
        /// functions of this ArrayList in accordance with the respective
        /// documentation. In all cases, "invalidated" means that the memory
        /// has been passed to an allocator's resize or free function.
        items: Slice = &[_]T{},
        cap_alloc: CapacityAllocated = .{},

        /// An ArrayList containing no elements.
        pub const empty: This = .{};

        const CapacityAllocated = packed struct {
            allocated: u1 = 0,
            capacity: usizem1 = 0,
        };

        const usizem1 = std.meta.Int(.unsigned, @bitSizeOf(usize) - 1);

        /// Maximum capacity of the list.
        pub const max_capacity: usize = std.math.maxInt(usizem1);

        /// How many T values this list can hold without allocating
        /// additional memory.
        fn capacity(this: This) usize {
            return this.cap_alloc.capacity;
        }

        /// Initialize with externally-managed memory. The buffer determines the
        /// capacity, and the length is set to zero.
        ///
        /// The list will only allocate if the size exceed the buffer's lenthg
        /// Assert that `buf.len` <= `max_capacity`
        pub fn initBuffer(buf: Slice) This {
            std.debug.assert(buf.len <= max_capacity);
            return .{
                .items = buf[0..0],
                .cap_alloc = .{ .capacity = @intCast(buf.len) },
            };
        }

        /// Initialize with capacity to hold `num` elements.
        /// The resulting capacity will equal `num` exactly.
        /// Deinitialize with `deinit` or use `toOwnedSlice`.
        ///
        /// Assert that `num` <= `max_capacity`
        pub fn initCapacity(al: Allocator, num: usize) Allocator.Error!This {
            std.debug.assert(num <= max_capacity);
            var this: This = .empty;
            try this.ensureTotalCapacityPrecise(al, num);
            return this;
        }

        /// Releases all allocated memory.
        pub fn deinit(this: *This, al: Allocator) void {
            if (this.cap_alloc.allocated != 0)
                al.free(this.allocatedSlice());
            this.* = undefined;
        }

        /// Invalidates all element pointers.
        pub fn clearAndFree(this: *This, al: Allocator) void {
            if (this.cap_alloc.allocated != 0)
                al.free(this.allocatedSlice());
            this.items.len = 0;
            this.cap_alloc = .{ .allocated = 0, .capacity = 0 };
        }

        /// Creates a copy of this ArrayList, using the same allocator.
        pub fn clone(this: This, al: Allocator) Allocator.Error!This {
            var cloned = try initCapacity(al, this.capacity());
            cloned.appendSliceAssumeCapacity(this.items);
            return cloned;
        }

        /// Insert `item` at index `i`. Moves `list[i .. list.len]` to higher indices to make room.
        /// If `i` is equal to the length of the list this operation is equivalent to append.
        /// This operation is O(N).
        /// Invalidates element pointers if additional memory is needed.
        /// Asserts that the index is in bounds or equal to the length.
        pub fn insert(this: *This, al: Allocator, i: usize, item: T) Allocator.Error!void {
            const dst = try this.addManyAt(al, i, 1);
            dst[0] = item;
        }

        /// Add `count` new elements at position `index`, which have
        /// `undefined` values. Returns a slice pointing to the newly allocated
        /// elements, which becomes invalid after various `ArrayList`
        /// operations.
        /// Invalidates pre-existing pointers to elements at and after `index`.
        /// Invalidates all pre-existing element pointers if capacity must be
        /// increased to accommodate the new elements.
        /// Asserts that the index is in bounds or equal to the length.
        pub fn addManyAt(
            this: *This,
            al: Allocator,
            index: usize,
            count: usize,
        ) Allocator.Error![]T {
            const new_len = try addOrOom(this.items.len, count);
            std.debug.assert(new_len <= max_capacity);

            if (this.capacity() >= new_len)
                return addManyAtAssumeCapacity(this, index, count);

            // Here we avoid copying allocated but unused bytes by
            // attempting a resize in place, and falling back to allocating
            // a new buffer and doing our own copy. With a realloc() call,
            // the allocator implementation would pointlessly copy our
            // extra capacity.
            const new_capacity = growCapacity(this.cap_alloc.capacity, @intCast(new_len));
            const old_memory = this.allocatedSlice();
            if (al.remap(old_memory, new_capacity)) |new_memory| {
                this.items.ptr = new_memory.ptr;
                this.cap_alloc.capacity = new_capacity;
                this.cap_alloc.allocated = 1;
                return addManyAtAssumeCapacity(this, index, count);
            }

            // Make a new allocation, avoiding `ensureTotalCapacity` in order
            // to avoid extra memory copies.
            const new_memory = try al.alignedAlloc(T, alignment, new_capacity);
            const to_move = this.items[index..];
            @memcpy(new_memory[0..index], this.items[0..index]);
            @memcpy(new_memory[index + count ..][0..to_move.len], to_move);
            al.free(old_memory);
            this.items = new_memory[0..new_len];
            this.cap_alloc.capacity = new_capacity;
            this.cap_alloc.allocated = 1;
            // The inserted elements at `new_memory[index..][0..count]` have
            // already been set to `undefined` by memory allocation.
            return new_memory[index..][0..count];
        }

        /// Append the slice of items to the list.
        ///
        /// Asserts that the list can hold the additional items.
        pub fn appendSliceAssumeCapacity(this: *This, items: []const T) void {
            const old_len = this.items.len;
            const new_len = old_len + items.len;
            std.debug.assert(new_len <= this.capacity());
            this.items.len = new_len;
            @memcpy(this.items[old_len..][0..items.len], items);
        }

        /// Extends the list by 1 element. Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn append(this: *This, al: Allocator, item: T) !void {
            // asm volatile ("; buf.append");
            (try this.addOne(al)).* = item;
        }

        /// Extends the list by 1 element.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn appendAssumeCapacity(this: *This, item: T) void {
            // asm volatile ("; buf.appendAssumeCapacity");
            this.addOneAssumeCapacity().* = item;
        }

        /// Increase length by 1, returning pointer to the new item.
        /// The returned pointer becomes invalid when the list is resized.
        /// Never invalidates element pointers.
        /// Asserts that the list can hold one additional item.
        pub fn addOneAssumeCapacity(this: *This) *T {
            // asm volatile ("; buf.addOneAssumeCapacity");
            std.debug.assert(this.items.len < this.capacity());

            this.items.len += 1;
            return &this.items[this.items.len - 1];
        }

        /// Increase length by 1, returning pointer to the new item.
        /// The returned pointer becomes invalid when the list resized.
        pub fn addOne(this: *This, al: Allocator) !*T {
            // asm volatile ("; buf.addOne");
            try this.ensureTotalCapacity(al, this.items.len + 1);
            return this.addOneAssumeCapacity();
        }

        /// Remove the element at index `i`, shift elements after index
        /// `i` forward, and return the removed element.
        /// Invalidates element pointers to end of list.
        /// This operation is O(N).
        /// This preserves item order. Use `swapRemove` if order preservation is not important.
        /// Asserts that the index is in bounds.
        /// Asserts that the list is not empty.
        pub fn orderedRemove(this: *This, i: usize) T {
            const old_item = this.items[i];
            this.replaceRangeAssumeCapacity(i, 1, &.{});
            return old_item;
        }

        /// Removes the element at the specified index and returns it.
        /// The empty slot is filled from the end of the list.
        /// Invalidates pointers to last element.
        /// This operation is O(1).
        /// Asserts that the list is not empty.
        /// Asserts that the index is in bounds.
        pub fn swapRemove(this: *This, i: usize) T {
            if (this.items.len - 1 == i) return this.pop().?;

            const old_item = this.items[i];
            this.items[i] = this.pop().?;
            return old_item;
        }

        /// Append the slice of items to the list. Allocates more
        /// memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendSlice(this: *This, al: Allocator, items: []const T) Allocator.Error!void {
            try this.ensureUnusedCapacity(al, items.len);
            this.appendSliceAssumeCapacity(items);
        }

        /// Append the slice of items to the list. Allocates more
        /// memory as necessary. Only call this function if a call to `appendSlice` instead would
        /// be a compile error.
        /// Invalidates element pointers if additional memory is needed.
        pub fn appendUnalignedSlice(this: *This, al: Allocator, items: []align(1) const T) Allocator.Error!void {
            try this.ensureUnusedCapacity(al, items.len);
            this.appendUnalignedSliceAssumeCapacity(items);
        }

        /// Append an unaligned slice of items to the list.
        ///
        /// Intended to be used only when `appendSliceAssumeCapacity` would be
        /// a compile error.
        ///
        /// Asserts that the list can hold the additional items.
        pub fn appendUnalignedSliceAssumeCapacity(this: *This, items: []align(1) const T) void {
            const old_len = this.items.len;
            const new_len = old_len + items.len;
            std.debug.assert(new_len <= this.capacity());
            this.items.len = new_len;
            @memcpy(this.items[old_len..][0..items.len], items);
        }

        /// Remove and return the last element from the list, or return `null`
        /// if list is empty.
        ///
        /// Invalidates element pointers to the removed element, if any.
        pub fn pop(this: *This) ?T {
            if (this.items.len == 0) return null;
            const val = this.items[this.items.len - 1];
            this.items.len -= 1;
            return val;
        }

        /// Append a value to the list `n` times.
        /// Allocates more memory as necessary.
        /// Invalidates element pointers if additional memory is needed.
        /// The function is inline so that a comptime-known `value` parameter will
        /// have a more optimal memset codegen in case it has a repeated byte pattern.
        pub inline fn appendNTimes(this: *This, al: Allocator, value: T, n: usize) Allocator.Error!void {
            const old_len = this.items.len;
            try this.resize(al, try addOrOom(old_len, n));
            @memset(this.items[old_len..this.items.len], value);
        }

        /// Append a value to the list `n` times.
        ///
        /// Never invalidates element pointers.
        ///
        /// The function is inline so that a comptime-known `value` parameter will
        /// have better memset codegen in case it has a repeated byte pattern.
        ///
        /// Asserts that the list can hold the additional items.
        pub inline fn appendNTimesAssumeCapacity(this: *This, value: T, n: usize) void {
            const new_len = this.items.len + n;
            std.debug.assert(new_len <= this.capacity);
            @memset(this.items.ptr[this.items.len..new_len], value);
            this.items.len = new_len;
        }

        /// Adjust the list length to `new_len`.
        /// Additional elements contain the value `undefined`.
        /// Invalidates element pointers if additional memory is needed.
        pub fn resize(this: *This, al: Allocator, new_len: usize) Allocator.Error!void {
            try this.ensureTotalCapacity(al, new_len);
            this.items.len = new_len;
        }

        /// Add `count` new elements at position `index`, which have
        /// `undefined` values. Returns a slice pointing to the newly allocated
        /// elements, which becomes invalid after various `ArrayList`
        /// operations.
        /// Invalidates pre-existing pointers to elements at and after `index`, but
        /// does not invalidate any before that.
        /// Asserts that the list has capacity for the additional items.
        /// Asserts that the index is in bounds or equal to the length.
        pub fn addManyAtAssumeCapacity(this: *This, index: usize, count: usize) []T {
            const new_len = this.items.len + count;
            std.debug.assert(this.capacity() >= new_len);
            const to_move = this.items[index..];
            this.items.len = new_len;
            @memmove(this.items[index + count ..][0..to_move.len], to_move);
            const result = this.items[index..][0..count];
            @memset(result, undefined);
            return result;
        }

        /// Insert slice `items` at index `i` by moving `list[i .. list.len]` to make room.
        /// This operation is O(N).
        /// Invalidates pre-existing pointers to elements at and after `index`.
        /// Invalidates all pre-existing element pointers if capacity must be
        /// increased to accommodate the new elements.
        /// Asserts that the index is in bounds or equal to the length.
        pub fn insertSlice(
            this: *This,
            al: Allocator,
            index: usize,
            items: []const T,
        ) Allocator.Error!void {
            const dst = try this.addManyAt(
                al,
                index,
                items.len,
            );
            @memcpy(dst, items);
        }


        /// Grows or shrinks the list as necessary.
        /// Invalidates element pointers if additional capacity is allocated.
        /// Asserts that the range is in bounds.
        pub fn replaceRange(
            this: *This,
            al: Allocator,
            start: usize,
            len: usize,
            new_items: []const T,
        ) Allocator.Error!void {
            const after_range = start + len;
            const range = this.items[start..after_range];
            if (range.len < new_items.len) {
                const first = new_items[0..range.len];
                const rest = new_items[range.len..];
                @memcpy(range[0..first.len], first);
                try this.insertSlice(al, after_range, rest);
            } else {
                this.replaceRangeAssumeCapacity(start, len, new_items);
            }
        }

        /// Grows or shrinks the list as necessary.
        ///
        /// Never invalidates element pointers.
        ///
        /// Asserts the capacity is enough for additional items.
        pub fn replaceRangeAssumeCapacity(this: *This, start: usize, len: usize, new_items: []const T) void {
            const after_range = start + len;
            const range = this.items[start..after_range];

            if (range.len == new_items.len)
                @memcpy(range[0..new_items.len], new_items)
            else if (range.len < new_items.len) {
                const first = new_items[0..range.len];
                const rest = new_items[range.len..];
                @memcpy(range[0..first.len], first);
                const dst = this.addManyAtAssumeCapacity(after_range, rest.len);
                @memcpy(dst, rest);
            } else {
                const extra = range.len - new_items.len;
                @memcpy(range[0..new_items.len], new_items);
                const src = this.items[after_range..];
                @memmove(this.items[after_range - extra ..][0..src.len], src);
                @memset(this.items[this.items.len - extra ..], undefined);
                this.items.len -= extra;
            }
        }

        /// Modify the array so that it can hold at least `new_capacity` items.
        /// Implements super-linear growth to achieve amortized O(1) append
        /// operations.
        ///
        /// Invalidates element pointers if additional memory is needed.
        ///
        /// Asserts that `new_cap <= max_capacity`.
        pub fn ensureTotalCapacity(
            this: *This,
            al: Allocator,
            new_cap: usize,
        ) Allocator.Error!void {
            // asm volatile ("; buf.ensureTotalCapacity");
            std.debug.assert(new_cap <= max_capacity);

            if (this.capacity() >= new_cap) {
                @branchHint(.likely);
                return;
            }

            return this.ensureTotalCapacityPrecise(
                al,
                growCapacity(this.cap_alloc.capacity, @intCast(new_cap)),
            );
        }

        /// If the current capacity is less than `new_capacity`, this function
        /// will modify the array so that it can hold exactly `new_capacity`
        /// items.
        ///
        /// Invalidates element pointers if additional memory is needed.
        ///
        /// Asserts that `new_cap <= max_capacity`.
        pub fn ensureTotalCapacityPrecise(
            this: *This,
            al: Allocator,
            new_cap: usize,
        ) Allocator.Error!void {
            // asm volatile ("; buf.ensureTotalCapacityPrecise");
            std.debug.assert(new_cap <= max_capacity);
            if (this.capacity() >= new_cap) {
                @branchHint(.likely);
                return;
            }

            const new_cap1: usizem1 = @intCast(new_cap);

            // if (this.cap_alloc.allocated == 0) {
            //     const new_mem = try al.alignedAlloc(T, alignment, new_cap);
            //     @memcpy(new_mem[0..this.items.len], this.items);
            //     this.items.ptr = new_mem.ptr;
            //     this.cap_alloc.capacity = new_cap1;
            //     this.cap_alloc.allocated = 1;
            //     return;
            // }

            // const old_mem = this.allocatedSlice();
            var old_mem = this.allocatedSlice();
            if (this.cap_alloc.allocated == 0) old_mem.len = 0;
            //)this.items.ptr[0..this.cap_alloc.capacity];
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

        /// Modify the array so that it can hold at least `additional_count`
        /// **more** items.
        ///
        /// Invalidates element pointers if additional memory is needed.
        pub fn ensureUnusedCapacity(
            this: *This,
            al: Allocator,
            additional_count: usize,
        ) Allocator.Error!void {
            return this.ensureTotalCapacity(al, try addOrOom(this.items.len, additional_count));
        }

        fn growCapacity(current: usizem1, minimum: usizem1) usizem1 {
            // asm volatile ("; buf.growCapacity");
            var new = current;
            while (true) {
                new +|= new / 2 + init_capacity;
                if (new >= minimum)
                    return new;
            }
        }

        /// Returns a slice of all the items plus the extra capacity, whose
        /// memory contents are `undefined`.
        pub fn allocatedSlice(this: This) Slice {
            return this.items.ptr[0..this.cap_alloc.capacity];
        }
    };
}
///
/// Integer addition returning `error.OutOfMemory` on overflow.
fn addOrOom(a: usize, b: usize) error{OutOfMemory}!usize {
    const result, const overflow = @addWithOverflow(a, b);
    if (overflow != 0) return error.OutOfMemory;
    return result;
}

const testing = std.testing;

test "init" {
    {
        const list: ArrayList(i32) = .empty;

        try testing.expect(list.items.len == 0);
        try testing.expect(list.capacity() == 0);
    }
}

test "initCapacity" {
    const a = testing.allocator;
    {
        var list = try ArrayList(i8).initCapacity(a, 200);
        defer list.deinit(a);
        try testing.expect(list.items.len == 0);
        try testing.expect(list.capacity() >= 200);
    }
}

test "clone" {
    const a = testing.allocator;

    {
        var array: ArrayList(i32) = .empty;
        try array.append(a, -1);
        try array.append(a, 3);
        try array.append(a, 5);

        var cloned = try array.clone(a);
        defer cloned.deinit(a);

        try testing.expectEqualSlices(i32, array.items, cloned.items);
        try testing.expect(cloned.capacity() >= array.capacity());

        array.deinit(a);

        try testing.expectEqual(@as(i32, -1), cloned.items[0]);
        try testing.expectEqual(@as(i32, 3), cloned.items[1]);
        try testing.expectEqual(@as(i32, 5), cloned.items[2]);
    }
}

test "basic" {
    const a = testing.allocator;
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);

        {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                list.append(a, @as(i32, @intCast(i + 1))) catch unreachable;
            }
        }

        {
            var i: usize = 0;
            while (i < 10) : (i += 1) {
                try testing.expect(list.items[i] == @as(i32, @intCast(i + 1)));
            }
        }

        for (list.items, 0..) |v, i| {
            try testing.expect(v == @as(i32, @intCast(i + 1)));
        }

        try testing.expect(list.pop() == 10);
        try testing.expect(list.items.len == 9);

        list.appendSlice(a, &[_]i32{ 1, 2, 3 }) catch unreachable;
        try testing.expect(list.items.len == 12);
        try testing.expect(list.pop() == 3);
        try testing.expect(list.pop() == 2);
        try testing.expect(list.pop() == 1);
        try testing.expect(list.items.len == 9);

        var unaligned: [3]i32 align(1) = [_]i32{ 4, 5, 6 };
        list.appendUnalignedSlice(a, &unaligned) catch unreachable;
        try testing.expect(list.items.len == 12);
        try testing.expect(list.pop() == 6);
        try testing.expect(list.pop() == 5);
        try testing.expect(list.pop() == 4);
        try testing.expect(list.items.len == 9);

        list.appendSlice(a, &[_]i32{}) catch unreachable;
        try testing.expect(list.items.len == 9);

        // can only set on indices < self.items.len
        list.items[7] = 33;
        list.items[8] = 42;

        try testing.expect(list.pop() == 42);
        try testing.expect(list.pop() == 33);
    }
}

test "appendNTimes" {
    const a = testing.allocator;
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);

        try list.appendNTimes(a, 2, 10);
        try testing.expectEqual(@as(usize, 10), list.items.len);
        for (list.items) |element| {
            try testing.expectEqual(@as(i32, 2), element);
        }
    }
}

test "appendNTimes with failing allocator" {
    const a = testing.failing_allocator;
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try testing.expectError(error.OutOfMemory, list.appendNTimes(a, 2, 10));
    }
}

test "orderedRemove" {
    const a = testing.allocator;
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);

        try list.append(a, 1);
        try list.append(a, 2);
        try list.append(a, 3);
        try list.append(a, 4);
        try list.append(a, 5);
        try list.append(a, 6);
        try list.append(a, 7);

        //remove from middle
        try testing.expectEqual(@as(i32, 4), list.orderedRemove(3));
        try testing.expectEqual(@as(i32, 5), list.items[3]);
        try testing.expectEqual(@as(usize, 6), list.items.len);

        //remove from end
        try testing.expectEqual(@as(i32, 7), list.orderedRemove(5));
        try testing.expectEqual(@as(usize, 5), list.items.len);

        //remove from front
        try testing.expectEqual(@as(i32, 1), list.orderedRemove(0));
        try testing.expectEqual(@as(i32, 2), list.items[0]);
        try testing.expectEqual(@as(usize, 4), list.items.len);
    }
    {
        // remove last item
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.append(a, 1);
        try testing.expectEqual(@as(i32, 1), list.orderedRemove(0));
        try testing.expectEqual(@as(usize, 0), list.items.len);
    }
}

test "swapRemove" {
    const a = testing.allocator;

    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);

        try list.append(a, 1);
        try list.append(a, 2);
        try list.append(a, 3);
        try list.append(a, 4);
        try list.append(a, 5);
        try list.append(a, 6);
        try list.append(a, 7);

        //remove from middle
        try testing.expect(list.swapRemove(3) == 4);
        try testing.expect(list.items[3] == 7);
        try testing.expect(list.items.len == 6);

        //remove from end
        try testing.expect(list.swapRemove(5) == 6);
        try testing.expect(list.items.len == 5);

        //remove from front
        try testing.expect(list.swapRemove(0) == 1);
        try testing.expect(list.items[0] == 5);
        try testing.expect(list.items.len == 4);
    }
}

test "insert" {
    const a = testing.allocator;

    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);

        try list.insert(a, 0, 1);
        try list.append(a, 2);
        try list.insert(a, 2, 3);
        try list.insert(a, 0, 5);
        try testing.expect(list.items[0] == 5);
        try testing.expect(list.items[1] == 1);
        try testing.expect(list.items[2] == 2);
        try testing.expect(list.items[3] == 3);
    }
}

test "insertSlice" {
    const a = testing.allocator;
    
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);

        try list.append(a, 1);
        try list.append(a, 2);
        try list.append(a, 3);
        try list.append(a, 4);
        try list.insertSlice(a, 1, &[_]i32{ 9, 8 });
        try testing.expect(list.items[0] == 1);
        try testing.expect(list.items[1] == 9);
        try testing.expect(list.items[2] == 8);
        try testing.expect(list.items[3] == 2);
        try testing.expect(list.items[4] == 3);
        try testing.expect(list.items[5] == 4);

        const items = [_]i32{1};
        try list.insertSlice(a, 0, items[0..0]);
        try testing.expect(list.items.len == 6);
        try testing.expect(list.items[0] == 1);
    }
}

test "ArrayList.replaceRange" {
    const a = testing.allocator;

    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        try list.replaceRange(a, 1, 0, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0, 2, 3, 4, 5 }, list.items);
    }
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        try list.replaceRange(a, 1, 1, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(
            i32,
            &[_]i32{ 1, 0, 0, 0, 3, 4, 5 },
            list.items,
        );
    }
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        try list.replaceRange(a, 1, 2, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0, 4, 5 }, list.items);
    }
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        try list.replaceRange(a, 1, 3, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0, 5 }, list.items);
    }
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        try list.replaceRange(a, 1, 4, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0 }, list.items);
    }
}

test "ArrayList.replaceRangeAssumeCapacity" {
    const a = testing.allocator;

    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        list.replaceRangeAssumeCapacity(1, 0, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0, 2, 3, 4, 5 }, list.items);
    }
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        list.replaceRangeAssumeCapacity(1, 1, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(
            i32,
            &[_]i32{ 1, 0, 0, 0, 3, 4, 5 },
            list.items,
        );
    }
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        list.replaceRangeAssumeCapacity(1, 2, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0, 4, 5 }, list.items);
    }
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        list.replaceRangeAssumeCapacity(1, 3, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0, 5 }, list.items);
    }
    {
        var list: ArrayList(i32) = .empty;
        defer list.deinit(a);
        try list.appendSlice(a, &[_]i32{ 1, 2, 3, 4, 5 });

        list.replaceRangeAssumeCapacity(1, 4, &[_]i32{ 0, 0, 0 });

        try testing.expectEqualSlices(i32, &[_]i32{ 1, 0, 0, 0 }, list.items);
    }
}

// const ItemUnmanaged = struct {
//     integer: i32,
//     sub_items: ArrayList(ItemUnmanaged),
// };
//
// test "Managed(T) of struct T" {
//     const a = std.testing.allocator;
//     {
//         var root = ItemUnmanaged{ .integer = 1, .sub_items = .empty };
//         defer root.sub_items.deinit(a);
//         try root.sub_items.append(a, ItemUnmanaged{ .integer = 42, .sub_items = .empty });
//         try testing.expect(root.sub_items.items[0].integer == 42);
//     }
// }


// test "shrink still sets length when resizing is disabled" {
//     var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
//     const a = failing_allocator.allocator();
//
//     {
//         var list = Managed(i32).init(a);
//         defer list.deinit();
//
//         try list.append(1);
//         try list.append(2);
//         try list.append(3);
//
//         list.shrinkAndFree(1);
//         try testing.expect(list.items.len == 1);
//     }
//     {
//         var list: ArrayList(i32) = .empty;
//         defer list.deinit(a);
//
//         try list.append(a, 1);
//         try list.append(a, 2);
//         try list.append(a, 3);
//
//         list.shrinkAndFree(a, 1);
//         try testing.expect(list.items.len == 1);
//     }
// }
//
// test "shrinkAndFree with a copy" {
//     var failing_allocator = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
//     const a = failing_allocator.allocator();
//
//     var list = Managed(i32).init(a);
//     defer list.deinit();
//
//     try list.appendNTimes(3, 16);
//     list.shrinkAndFree(4);
//     try testing.expect(mem.eql(i32, list.items, &.{ 3, 3, 3, 3 }));
// }
//
// test "addManyAsArray" {
//     const a = std.testing.allocator;
//     {
//         var list = Managed(u8).init(a);
//         defer list.deinit();
//
//         (try list.addManyAsArray(4)).* = "aoeu".*;
//         try list.ensureTotalCapacity(8);
//         list.addManyAsArrayAssumeCapacity(4).* = "asdf".*;
//
//         try testing.expectEqualSlices(u8, list.items, "aoeuasdf");
//     }
//     {
//         var list: ArrayList(u8) = .empty;
//         defer list.deinit(a);
//
//         (try list.addManyAsArray(a, 4)).* = "aoeu".*;
//         try list.ensureTotalCapacity(a, 8);
//         list.addManyAsArrayAssumeCapacity(4).* = "asdf".*;
//
//         try testing.expectEqualSlices(u8, list.items, "aoeuasdf");
//     }
// }
//
// test "growing memory preserves contents" {
//     // Shrink the list after every insertion to ensure that a memory growth
//     // will be triggered in the next operation.
//     const a = std.testing.allocator;
//     {
//         var list = Managed(u8).init(a);
//         defer list.deinit();
//
//         (try list.addManyAsArray(4)).* = "abcd".*;
//         list.shrinkAndFree(4);
//
//         try list.appendSlice("efgh");
//         try testing.expectEqualSlices(u8, list.items, "abcdefgh");
//         list.shrinkAndFree(8);
//
//         try list.insertSlice(4, "ijkl");
//         try testing.expectEqualSlices(u8, list.items, "abcdijklefgh");
//     }
//     {
//         var list: ArrayList(u8) = .empty;
//         defer list.deinit(a);
//
//         (try list.addManyAsArray(a, 4)).* = "abcd".*;
//         list.shrinkAndFree(a, 4);
//
//         try list.appendSlice(a, "efgh");
//         try testing.expectEqualSlices(u8, list.items, "abcdefgh");
//         list.shrinkAndFree(a, 8);
//
//         try list.insertSlice(a, 4, "ijkl");
//         try testing.expectEqualSlices(u8, list.items, "abcdijklefgh");
//     }
// }
//
// test "fromOwnedSlice" {
//     const a = testing.allocator;
//     {
//         var orig_list = Managed(u8).init(a);
//         defer orig_list.deinit();
//         try orig_list.appendSlice("foobar");
//
//         const slice = try orig_list.toOwnedSlice();
//         var list = Managed(u8).fromOwnedSlice(a, slice);
//         defer list.deinit();
//         try testing.expectEqualStrings(list.items, "foobar");
//     }
//     {
//         var list = Managed(u8).init(a);
//         defer list.deinit();
//         try list.appendSlice("foobar");
//
//         const slice = try list.toOwnedSlice();
//         var unmanaged = ArrayList(u8).fromOwnedSlice(slice);
//         defer unmanaged.deinit(a);
//         try testing.expectEqualStrings(unmanaged.items, "foobar");
//     }
// }
//
// test "fromOwnedSliceSentinel" {
//     const a = testing.allocator;
//     {
//         var orig_list = Managed(u8).init(a);
//         defer orig_list.deinit();
//         try orig_list.appendSlice("foobar");
//
//         const sentinel_slice = try orig_list.toOwnedSliceSentinel(0);
//         var list = Managed(u8).fromOwnedSliceSentinel(a, 0, sentinel_slice);
//         defer list.deinit();
//         try testing.expectEqualStrings(list.items, "foobar");
//     }
//     {
//         var list = Managed(u8).init(a);
//         defer list.deinit();
//         try list.appendSlice("foobar");
//
//         const sentinel_slice = try list.toOwnedSliceSentinel(0);
//         var unmanaged = ArrayList(u8).fromOwnedSliceSentinel(0, sentinel_slice);
//         defer unmanaged.deinit(a);
//         try testing.expectEqualStrings(unmanaged.items, "foobar");
//     }
// }
//
// test "toOwnedSliceSentinel" {
//     const a = testing.allocator;
//     {
//         var list = Managed(u8).init(a);
//         defer list.deinit();
//
//         try list.appendSlice("foobar");
//
//         const result = try list.toOwnedSliceSentinel(0);
//         defer a.free(result);
//         try testing.expectEqualStrings(result, mem.sliceTo(result.ptr, 0));
//     }
//     {
//         var list: ArrayList(u8) = .empty;
//         defer list.deinit(a);
//
//         try list.appendSlice(a, "foobar");
//
//         const result = try list.toOwnedSliceSentinel(a, 0);
//         defer a.free(result);
//         try testing.expectEqualStrings(result, mem.sliceTo(result.ptr, 0));
//     }
// }
//
// test "accepts unaligned slices" {
//     const a = testing.allocator;
//     {
//         var list = AlignedManaged(u8, .@"8").init(a);
//         defer list.deinit();
//
//         try list.appendSlice(&.{ 0, 1, 2, 3 });
//         try list.insertSlice(2, &.{ 4, 5, 6, 7 });
//         try list.replaceRange(1, 3, &.{ 8, 9 });
//
//         try testing.expectEqualSlices(u8, list.items, &.{ 0, 8, 9, 6, 7, 2, 3 });
//     }
//     {
//         var list: Aligned(u8, .@"8") = .empty;
//         defer list.deinit(a);
//
//         try list.appendSlice(a, &.{ 0, 1, 2, 3 });
//         try list.insertSlice(a, 2, &.{ 4, 5, 6, 7 });
//         try list.replaceRange(a, 1, 3, &.{ 8, 9 });
//
//         try testing.expectEqualSlices(u8, list.items, &.{ 0, 8, 9, 6, 7, 2, 3 });
//     }
// }
//
// test "Managed(u0)" {
//     // An Managed on zero-sized types should not need to allocate
//     const a = testing.failing_allocator;
//
//     var list = Managed(u0).init(a);
//     defer list.deinit();
//
//     try list.append(0);
//     try list.append(0);
//     try list.append(0);
//     try testing.expectEqual(list.items.len, 3);
//
//     var count: usize = 0;
//     for (list.items) |x| {
//         try testing.expectEqual(x, 0);
//         count += 1;
//     }
//     try testing.expectEqual(count, 3);
// }
//
// test "Managed(?u32).pop()" {
//     const a = testing.allocator;
//
//     var list = Managed(?u32).init(a);
//     defer list.deinit();
//
//     try list.append(null);
//     try list.append(1);
//     try list.append(2);
//     try testing.expectEqual(list.items.len, 3);
//
//     try testing.expect(list.pop().? == @as(u32, 2));
//     try testing.expect(list.pop().? == @as(u32, 1));
//     try testing.expect(list.pop().? == null);
//     try testing.expect(list.pop() == null);
// }
//
// test "Managed(u32).getLast()" {
//     const a = testing.allocator;
//
//     var list = Managed(u32).init(a);
//     defer list.deinit();
//
//     try list.append(2);
//     const const_list = list;
//     try testing.expectEqual(const_list.getLast(), 2);
// }
//
// test "Managed(u32).getLastOrNull()" {
//     const a = testing.allocator;
//
//     var list = Managed(u32).init(a);
//     defer list.deinit();
//
//     try testing.expectEqual(list.getLastOrNull(), null);
//
//     try list.append(2);
//     const const_list = list;
//     try testing.expectEqual(const_list.getLastOrNull().?, 2);
// }
//
// test "return OutOfMemory when capacity would exceed maximum usize integer value" {
//     const a = testing.allocator;
//     const new_item: u32 = 42;
//     const items = &.{ 42, 43 };
//
//     {
//         var list: ArrayList(u32) = .{
//             .items = undefined,
//             .capacity = math.maxInt(usize) - 1,
//         };
//         list.items.len = math.maxInt(usize) - 1;
//
//         try testing.expectError(error.OutOfMemory, list.appendSlice(a, items));
//         try testing.expectError(error.OutOfMemory, list.appendNTimes(a, new_item, 2));
//         try testing.expectError(error.OutOfMemory, list.appendUnalignedSlice(a, &.{ new_item, new_item }));
//         try testing.expectError(error.OutOfMemory, list.addManyAt(a, 0, 2));
//         try testing.expectError(error.OutOfMemory, list.addManyAsArray(a, 2));
//         try testing.expectError(error.OutOfMemory, list.addManyAsSlice(a, 2));
//         try testing.expectError(error.OutOfMemory, list.insertSlice(a, 0, items));
//         try testing.expectError(error.OutOfMemory, list.ensureUnusedCapacity(a, 2));
//     }
//
//     {
//         var list: Managed(u32) = .{
//             .items = undefined,
//             .capacity = math.maxInt(usize) - 1,
//             .allocator = a,
//         };
//         list.items.len = math.maxInt(usize) - 1;
//
//         try testing.expectError(error.OutOfMemory, list.appendSlice(items));
//         try testing.expectError(error.OutOfMemory, list.appendNTimes(new_item, 2));
//         try testing.expectError(error.OutOfMemory, list.appendUnalignedSlice(&.{ new_item, new_item }));
//         try testing.expectError(error.OutOfMemory, list.addManyAt(0, 2));
//         try testing.expectError(error.OutOfMemory, list.addManyAsArray(2));
//         try testing.expectError(error.OutOfMemory, list.addManyAsSlice(2));
//         try testing.expectError(error.OutOfMemory, list.insertSlice(0, items));
//         try testing.expectError(error.OutOfMemory, list.ensureUnusedCapacity(2));
//     }
// }
//
// test "orderedRemoveMany" {
//     const gpa = testing.allocator;
//
//     var list: Aligned(usize, null) = .empty;
//     defer list.deinit(gpa);
//
//     for (0..10) |n| {
//         try list.append(gpa, n);
//     }
//
//     list.orderedRemoveMany(&.{ 1, 5, 5, 7, 9 });
//     try testing.expectEqualSlices(usize, &.{ 0, 2, 3, 4, 6, 8 }, list.items);
//
//     list.orderedRemoveMany(&.{0});
//     try testing.expectEqualSlices(usize, &.{ 2, 3, 4, 6, 8 }, list.items);
//
//     list.orderedRemoveMany(&.{});
//     try testing.expectEqualSlices(usize, &.{ 2, 3, 4, 6, 8 }, list.items);
//
//     list.orderedRemoveMany(&.{ 1, 2, 3, 4 });
//     try testing.expectEqualSlices(usize, &.{2}, list.items);
//
//     list.orderedRemoveMany(&.{0});
//     try testing.expectEqualSlices(usize, &.{}, list.items);
// }
