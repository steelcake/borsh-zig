const std = @import("std");
const FixedBufferAllocator = std.heap.FixedBufferAllocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const fuzzin = @import("fuzzin");
const borsh = @import("borsh");

const FuzzType = struct {
    name: [:0]const u8,
    nested: ?*const FuzzType,
    nesteds: ?[]const FuzzType,
    nesteds2: ?[]FuzzType,
    nested_arr: ?[3]*FuzzType,
    age: u256,
    age2: i128,
    age3: i8,
    ages: []const i32,
    ages2: []u64,
    ages3: []i16,
    opt: union(enum) {
        a: u32,
        b: enum(u128) {
            x = 123213,
            d = 6969,
            c,
        },
    },
    floa: f16,
    floatt: f32,
    floatttt: f64,
    arr: [69:5]u32,

    fn assert_eq(self: *const FuzzType, other: *const FuzzType) void {
        _ = self;
        _ = other;
    }
};

const SERDE_DEPTH_LIMIT = 32;
const INPUT_DEPTH_LIMIT = 32;

fn fuzz_deserialize(ctx: *anyopaque, input: *fuzzin.FuzzInput, dbg_alloc: Allocator) fuzzin.Error!void {
    _ = ctx;

    var arena = ArenaAllocator.init(dbg_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const input_bytes = input.all_bytes();

    _ = borsh.deserialize(
        FuzzType,
        input_bytes,
        alloc,
        SERDE_DEPTH_LIMIT,
    ) catch {};

    const out = borsh.deserialize_stream(
        FuzzType,
        input_bytes,
        alloc,
        SERDE_DEPTH_LIMIT,
    ) catch return;
    std.debug.assert(out.offset <= input_bytes.len);
}

test fuzz_deserialize {
    fuzzin.fuzz_test(undefined, fuzz_deserialize, 1 << 20);
}

const Context = struct {
    buf: []u8,
};

fn fuzz_roundtrip(ctx: *anyopaque, input: *fuzzin.FuzzInput, dbg_alloc: Allocator) fuzzin.Error!void {
    const buf = @as(*Context, @ptrCast(ctx)).buf;

    var arena = ArenaAllocator.init(dbg_alloc);
    defer arena.deinit();
    const alloc = arena.allocator();

    const t = try input.auto(FuzzType, alloc, INPUT_DEPTH_LIMIT);

    const len = borsh.serialize(
        *const FuzzType,
        &t,
        buf,
        SERDE_DEPTH_LIMIT,
    ) catch unreachable;

    const out = borsh.deserialize(
        FuzzType,
        buf[0..len],
        alloc,
        SERDE_DEPTH_LIMIT,
    ) catch unreachable;

    t.assert_eq(&out);
}

test fuzz_roundtrip {
    var ctx = Context{
        .buf = try std.heap.page_allocator.alloc(u8, 1 << 20),
    };
    fuzzin.fuzz_test(&ctx, fuzz_deserialize, 1 << 20);
}
