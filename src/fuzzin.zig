const std = @import("std");
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const fuzzin = @import("fuzzin");

const serde = @import("./serde.zig");

pub fn FuzzTest(comptime T: type, alloc_size: usize, max_depth: u8) type {
    return struct {
        const Self = @This();

        fn fuzz_deserialize_impl(ctx: void, input: *fuzzin.FuzzInput, dbg_alloc: Allocator) fuzzin.Error!void {
            _ = ctx;

            var arena = ArenaAllocator.init(dbg_alloc);
            defer arena.deinit();
            const alloc = arena.allocator();

            const input_bytes = input.all_bytes();

            _ = serde.deserialize(
                T,
                input_bytes,
                alloc,
                max_depth,
            ) catch {};

            const out = serde.deserialize_stream(
                T,
                input_bytes,
                alloc,
                max_depth,
            ) catch return;
            std.debug.assert(out.offset <= input_bytes.len);
        }

        pub fn fuzz_deserialize() void {
            fuzzin.fuzz_test(void, {}, fuzz_deserialize_impl, alloc_size);
        }

        const Context = struct {
            buf: []u8,
        };

        fn fuzz_roundtrip_impl(ctx: []u8, input: *fuzzin.FuzzInput, dbg_alloc: Allocator) fuzzin.Error!void {
            const buf = ctx;

            var arena = ArenaAllocator.init(dbg_alloc);
            defer arena.deinit();
            const alloc = arena.allocator();

            const t = try input.auto(T, alloc, max_depth);

            const len = serde.serialize(
                T,
                t,
                buf,
                max_depth,
            ) catch @panic("failed serialize");

            const out = serde.deserialize(
                T,
                buf[0..len],
                alloc,
                max_depth,
            ) catch @panic("failed deserialize");

            assert_eq(T, t, out);
        }

        pub fn fuzz_roundtrip() void {
            const buf = std.heap.page_allocator.alloc(u8, alloc_size) catch unreachable;
            fuzzin.fuzz_test([]u8, buf, fuzz_roundtrip_impl, alloc_size);
        }
    };
}

fn assert_eq(comptime T: type, left: T, right: T) void {
    switch (@typeInfo(T)) {
        .int, .float, .bool, .@"enum" => {
            std.debug.assert(left == right);
        },
        .void => {},
        .array => |arr_info| {
            for (0..arr_info.len) |idx| {
                assert_eq(arr_info.child, left[idx], right[idx]);
            }
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    std.debug.assert(left.len == right.len);

                    for (left, right) |l, r| {
                        assert_eq(ptr_info.child, l, r);
                    }
                },
                .one => {
                    assert_eq(ptr_info.child, left.*, right.*);
                },
                else => @compileError("unsupported type"),
            }
        },
        .@"struct" => |struct_info| {
            inline for (struct_info.fields) |field| {
                assert_eq(
                    field.type,
                    @field(left, field.name),
                    @field(right, field.name),
                );
            }
        },
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                @compileError("untagged union is not supported.");
            }

            std.debug.assert(@intFromEnum(left) == @intFromEnum(right));

            switch (left) {
                inline else => |l, tag| {
                    assert_eq(@TypeOf(l), l, @field(right, @tagName(tag)));
                },
            }
        },
        .optional => |opt_info| {
            if (left) |l| {
                const r = right orelse unreachable;

                assert_eq(opt_info.child, l, r);
            } else {
                std.debug.assert(right == null);
            }
        },
        else => @compileError("unsupported type"),
    }
}
