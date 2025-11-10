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
    bools: []bool,
    bools2: [15]bool,
    bb: bool,
    arr: [69:5]u32,
};

const Tester = borsh.FuzzTest(FuzzType, 1 << 20, 64);

test "roundtrip" {
    Tester.fuzz_roundtrip();
}

test "deserialize" {
    Tester.fuzz_deserialize();
}
