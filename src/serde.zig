const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SerializeError = error{
    /// Output buffer isn't big enough to hold the output
    BufferTooSmall,
    MaxRecursionDepthReached,
};

pub fn serialize(
    comptime T: type,
    val: T,
    buffer: []u8,
    max_recursion_depth: u8,
) SerializeError!usize {
    return try serialize_impl(T, val, buffer, 0, max_recursion_depth);
}

fn serialize_impl(
    comptime T: type,
    val: T,
    output: []u8,
    depth: u8,
    max_depth: u8,
) SerializeError!usize {
    if (depth >= max_depth) {
        return SerializeError.MaxRecursionDepthReached;
    }

    switch (@typeInfo(T)) {
        .int => |int_info| {
            if (int_info.bits % 8 != 0) {
                @compileError("unsupported integer type");
            }
            const num_bytes = int_info.bits / 8;
            if (output.len < num_bytes) {
                return SerializeError.BufferTooSmall;
            }

            @as([*][num_bytes]u8, @ptrCast(output.ptr))[0] = @bitCast(val);

            return num_bytes;
        },
        .float => |float_info| {
            switch (float_info.bits) {
                16, 32, 64 => {},
                else => @compileError("unsupported float type"),
            }

            const num_bytes = float_info.bits / 8;
            if (output.len < num_bytes) {
                return SerializeError.BufferTooSmall;
            }

            @as([*][num_bytes]u8, @ptrCast(output.ptr))[0] = @bitCast(val);
            return num_bytes;
        },
        .void => return 0,
        .bool => {
            if (output.len < 1) {
                return SerializeError.BufferTooSmall;
            }
            output.ptr[0] = @intFromBool(val);
            return 1;
        },
        .array => |array_info| {
            switch (@typeInfo(array_info.child)) {
                .float, .int, .bool => {
                    const num_bytes = @sizeOf(array_info.child) * array_info.len;

                    if (output.len < num_bytes) {
                        return SerializeError.BufferTooSmall;
                    }

                    @as([*][num_bytes]u8, output.ptr).* = @bitCast(val);

                    return num_bytes;
                },
                else => {
                    var n_written: usize = 0;
                    for (val) |elem| {
                        n_written += try serialize_impl(
                            array_info.child,
                            elem,
                            output[n_written..],
                            depth + 1,
                            max_depth,
                        );
                    }
                    return n_written;
                },
            }
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    var n_written: usize = try serialize_impl(
                        u32,
                        @intCast(val.len),
                        output,
                        depth + 1,
                        max_depth,
                    );

                    switch (@typeInfo(ptr_info.child)) {
                        .float, .int, .bool => {
                            const num_bytes = @sizeOf(ptr_info.child) * val.len;

                            if (output.len < num_bytes) {
                                return SerializeError.BufferTooSmall;
                            }

                            @memcpy(output.ptr, @as([]const u8, @ptrCast(val)));

                            return num_bytes;
                        },
                        else => {
                            for (val) |elem| {
                                n_written += try serialize_impl(
                                    ptr_info.child,
                                    elem,
                                    output[n_written..],
                                    depth + 1,
                                    max_depth,
                                );
                            }

                            return n_written;
                        },
                    }
                },
                .one => {
                    return try serialize_impl(
                        ptr_info.child,
                        val.*,
                        output,
                        depth + 1,
                        max_depth,
                    );
                },
                else => @compileError("unsupported type"),
            }
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError("tuple isn't supported");
            }
            var n_written: usize = 0;
            inline for (struct_info.fields) |field| {
                n_written += try serialize_impl(
                    field.type,
                    @field(val, field.name),
                    output[n_written..],
                    depth + 1,
                    max_depth,
                );
            }
            return n_written;
        },
        .@"enum" => |enum_info| {
            if (enum_info.fields.len >= 256) {
                @compileError("enum is too big to be represented by u8");
            }

            const tag = @intFromEnum(val);

            if (output.len < 1) {
                return SerializeError.BufferTooSmall;
            }

            inline for (enum_info.fields, 0..) |enum_field, i| {
                if (enum_field.value == tag) {
                    output[0] = i;
                    return 1;
                }
            }

            @panic("enum variant not found. this should never happen.");
        },
        .@"union" => |union_info| {
            const tag_t = union_info.tag_type orelse {
                @compileError("non tagged unions are not supported");
            };

            const tag_info = @typeInfo(tag_t).@"enum";

            if (tag_info.fields.len >= 256) {
                @compileError("tag enum is too big to be represented by u8");
            }

            if (output.len < 1) {
                return SerializeError.BufferTooSmall;
            }

            const tag = @intFromEnum(val);
            inline for (
                tag_info.fields,
                union_info.fields,
                0..,
            ) |tag_field, union_field, i| {
                if (tag_field.value == tag) {
                    output[0] = i;
                    return 1 + try serialize_impl(
                        union_field.type,
                        @field(val, union_field.name),
                        output[1..],
                        depth + 1,
                        max_depth,
                    );
                }
            }

            @panic("union variant not found. this should never happen.");
        },
        .optional => |opt_info| {
            if (output.len < 1) {
                return SerializeError.BufferTooSmall;
            }

            if (val) |v| {
                output[0] = 1;
                return 1 + try serialize_impl(
                    opt_info.child,
                    v,
                    output[1..],
                    depth + 1,
                    max_depth,
                );
            } else {
                output[0] = 0;
                return 1;
            }
        },
        else => @compileError("unsupported type"),
    }
}

pub const DeserializeError = error{
    OutOfMemory,
    MaxRecursionDepthReached,
    InvalidInput,
    /// There are remaining input data after finishing deserialisation
    RemaniningBytes,
    /// Input is smaller than expected
    InputTooSmall,
};

/// Deserialize the given type of object from given input buffer.
///
/// Errors if input is too small or too big.
///
/// Pointers and slices are allocated using the given allocator,
///     the output object doesn't borrow the input buffer in any way.
/// So the input buffer can be discarded after the deserialization is done.
pub fn deserialize(
    comptime T: type,
    input: []const u8,
    allocator: Allocator,
    max_recursion_depth: u8,
) DeserializeError!T {
    var offset: usize = 0;
    const out = try deserialize_impl(
        T,
        input,
        allocator,
        &offset,
        0,
        max_recursion_depth,
    );

    std.debug.assert(offset <= input.len);

    if (offset < input.len) {
        return DeserializeError.RemaniningBytes;
    }

    return out;
}

/// Same as `deserialize` but doesn't error if there are remaining input bytes
///     after finishing the deserialization.
///
/// It will return the offset that it reached when doing the deserialization.
///
/// Caller can continue processing input using `input[offset..]`.
pub fn deserialize_stream(
    comptime T: type,
    input: []const u8,
    allocator: Allocator,
    max_recursion_depth: u8,
) DeserializeError!struct { val: T, offset: usize } {
    var offset: usize = 0;
    const out = try deserialize_impl(
        T,
        input,
        allocator,
        &offset,
        0,
        max_recursion_depth,
    );
    std.debug.assert(offset <= input.len);
    return .{ .val = out, .offset = offset };
}

fn deserialize_impl(
    comptime T: type,
    input: []const u8,
    allocator: Allocator,
    offset: *usize,
    depth: u8,
    max_depth: u8,
) DeserializeError!T {
    if (depth >= max_depth) {
        return DeserializeError.MaxRecursionDepthReached;
    }

    switch (@typeInfo(T)) {
        .int => |int_info| {
            if (int_info.bits % 8 != 0) {
                @compileError("unsupported integer type");
            }
            const num_bytes = int_info.bits / 8;

            const in = input[offset.*..];

            if (in.len < num_bytes) {
                return DeserializeError.InputTooSmall;
            }

            offset.* += num_bytes;

            return @bitCast(@as([*]const [num_bytes]u8, @ptrCast(in.ptr))[0]);
        },
        .float => |float_info| {
            if (float_info.bits != 16 and float_info.bits != 32 and float_info.bits != 64) {
                @compileError("unsupported float type");
            }
            const num_bytes = float_info.bits / 8;

            const in = input[offset.*..];

            if (in.len < num_bytes) {
                return DeserializeError.InputTooSmall;
            }

            offset.* += num_bytes;

            return @bitCast(@as([*]const [num_bytes]u8, @ptrCast(in.ptr))[0]);
        },
        .void => return {},
        .bool => {
            const in = input[offset.*..];

            if (in.len == 0) {
                return DeserializeError.InputTooSmall;
            }

            const v = in[0];

            if (v > 1) {
                return DeserializeError.InvalidInput;
            }

            offset.* += 1;

            return v != 0;
        },
        .array => |array_info| {
            switch (@typeInfo(array_info.child)) {
                .bool => {
                    if (array_info.sentinel_ptr != null) {
                        @compileError("bool array with sentinel not supported");
                    }

                    const num_bytes = array_info.len;

                    const in = input[offset.*..];

                    if (in.len < num_bytes) {
                        return DeserializeError.InputTooSmall;
                    }

                    const out: [num_bytes]u8 = @as([*]const [num_bytes]u8, @ptrCast(in.ptr))[0];

                    offset.* += num_bytes;

                    for (out) |v| {
                        if (v > 1) {
                            return DeserializeError.InvalidInput;
                        }
                    }

                    var out_b: [num_bytes]bool = undefined;
                    for (0..array_info.len) |idx| {
                        out_b[idx] = out[idx] != 0;
                    }

                    return out_b;
                },
                .int, .float => {
                    const num_bytes = @sizeOf(array_info.child) * array_info.len;

                    const in = input[offset.*..];

                    if (in.len < num_bytes) {
                        return DeserializeError.InputTooSmall;
                    }

                    const out: [array_info.len]array_info.child = @bitCast(
                        @as([*]const [num_bytes]u8, @ptrCast(in.ptr))[0],
                    );

                    offset.* += num_bytes;

                    if (array_info.sentinel()) |sentinel| {
                        for (out) |v| {
                            if (v == sentinel) {
                                return DeserializeError.InvalidInput;
                            }
                        }

                        var out_with_sentinel: [array_info.len:sentinel]array_info.child = undefined;
                        inline for (0..array_info.len) |idx| {
                            out_with_sentinel[idx] = out[idx];
                        }

                        return out_with_sentinel;
                    } else {
                        return out;
                    }
                },
                else => {
                    if (array_info.sentinel_ptr != null) {
                        @compileError("non int/float array with sentinel isn't supported");
                    }

                    var val: [array_info.len]array_info.child = undefined;

                    inline for (0..array_info.len) |i| {
                        val[i] = try deserialize_impl(
                            array_info.child,
                            input,
                            allocator,
                            offset,
                            depth + 1,
                            max_depth,
                        );
                    }

                    return val;
                },
            }
        },
        .pointer => |ptr_info| {
            switch (ptr_info.size) {
                .slice => {
                    if (@sizeOf(ptr_info.child) > std.math.maxInt(u32)) {
                        @compileError("impossible");
                    }

                    const length = try deserialize_impl(
                        u32,
                        input,
                        allocator,
                        offset,
                        depth + 1,
                        max_depth,
                    );

                    if (@as(u64, length) * @sizeOf(ptr_info.child) > std.math.maxInt(usize) / 2) {
                        return DeserializeError.InvalidInput;
                    }

                    switch (@typeInfo(ptr_info.child)) {
                        .bool => {
                            if (ptr_info.sentinel_ptr != null) {
                                @compileError("bool slice with sentinel isn't supported");
                            }

                            const num_bytes = length;

                            const in = input[offset.*..];

                            if (in.len < num_bytes) {
                                return DeserializeError.InputTooSmall;
                            }

                            const out = try allocator.alloc(u8, num_bytes);
                            @memcpy(out, in.ptr);

                            offset.* += num_bytes;

                            for (out) |v| {
                                if (v > 1) {
                                    return DeserializeError.InvalidInput;
                                }
                            }

                            return @ptrCast(out);
                        },
                        .int, .float => {
                            const num_bytes = @sizeOf(ptr_info.child) * @as(usize, length);

                            const in = input[offset.*..];

                            if (in.len < num_bytes) {
                                return DeserializeError.InputTooSmall;
                            }

                            const out: []ptr_info.child = if (ptr_info.sentinel()) |sentinel|
                                try allocator.allocSentinel(
                                    ptr_info.child,
                                    length,
                                    sentinel,
                                )
                            else
                                try allocator.alloc(
                                    ptr_info.child,
                                    length,
                                );

                            @memcpy(@as([]u8, @ptrCast(out)), in[0..num_bytes]);

                            offset.* += num_bytes;

                            if (ptr_info.sentinel()) |sentinel| {
                                for (out) |v| {
                                    if (v == sentinel) {
                                        return DeserializeError.InvalidInput;
                                    }
                                }

                                return @ptrCast(out);
                            } else {
                                return out;
                            }
                        },
                        else => {
                            if (ptr_info.sentinel_ptr != null) {
                                @compileError("non int/float slice with sentinel isn't supported");
                            }

                            const out = try allocator.alloc(ptr_info.child, length);

                            for (0..length) |i| {
                                out[i] = try deserialize_impl(
                                    ptr_info.child,
                                    input,
                                    allocator,
                                    offset,
                                    depth + 1,
                                    max_depth,
                                );
                            }

                            return out;
                        },
                    }
                },
                .one => {
                    const out = try allocator.create(ptr_info.child);

                    out.* = try deserialize_impl(
                        ptr_info.child,
                        input,
                        allocator,
                        offset,
                        depth + 1,
                        max_depth,
                    );

                    return out;
                },
                .many => @compileError("many-pointer not supported"),
                .c => @compileError("c pointer not supported"),
            }
        },
        .@"struct" => |struct_info| {
            if (struct_info.is_tuple) {
                @compileError("tuple isn't supported");
            }

            var out: T = undefined;

            inline for (struct_info.fields) |field| {
                @field(out, field.name) = try deserialize_impl(
                    field.type,
                    input,
                    allocator,
                    offset,
                    depth + 1,
                    max_depth,
                );
            }

            return out;
        },
        .@"enum" => |enum_info| {
            if (enum_info.fields.len >= 256) {
                @compileError("enum is too big to be represented by u8");
            }

            const in = input[offset.*..];

            if (in.len == 0) {
                return DeserializeError.InputTooSmall;
            }

            const index = in[0];

            offset.* += 1;

            inline for (enum_info.fields, 0..) |enum_field, i| {
                if (index == i) {
                    return @enumFromInt(enum_field.value);
                }
            }

            return DeserializeError.InvalidInput;
        },
        .@"union" => |union_info| {
            const tag_t = union_info.tag_type orelse {
                @compileError("non tagged unions are not supported");
            };
            const tag_info = @typeInfo(tag_t).@"enum";

            if (tag_info.fields.len >= 256) {
                @compileError("tag enum is too big to be represented by u8");
            }

            const in = input[offset.*..];

            if (in.len == 0) {
                return DeserializeError.InputTooSmall;
            }

            const index = in[0];

            offset.* += 1;

            inline for (union_info.fields, 0..) |union_field, i| {
                if (index == i) {
                    const out = try deserialize_impl(
                        union_field.type,
                        input,
                        allocator,
                        offset,
                        depth + 1,
                        max_depth,
                    );
                    return @unionInit(T, union_field.name, out);
                }
            }

            return DeserializeError.InvalidInput;
        },
        .optional => |opt_info| {
            const is_valid = try deserialize_impl(
                bool,
                input,
                allocator,
                offset,
                depth + 1,
                max_depth,
            );

            if (is_valid) {
                const out = try deserialize_impl(
                    opt_info.child,
                    input,
                    allocator,
                    offset,
                    depth + 1,
                    max_depth,
                );
                return out;
            } else {
                return null;
            }
        },
        else => @compileError("unsupported type"),
    }
}
