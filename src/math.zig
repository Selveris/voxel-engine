const std = @import("std");

pub fn Vec2(comptime T: type) type {
    return VecN(T, 2);
}
pub fn Vec3(comptime T: type) type {
    return VecN(T, 3);
}
pub fn Vec4(comptime T: type) type {
    return VecN(T, 4);
}

pub fn VecN(comptime T: type, comptime size: usize) type {
    switch (@typeInfo(T)) {
        .Float => {}, // all floats are ok
        .Int => |info| {
            if (info.bits < 1) {
                @compileError("VecN type must have at least 1 bit: " ++ @typeName(T));
            }
        },
        else => {
            @compileError("VecN do not support type: " ++ @typeName(T));
        },
    }
    if (size < 2) {
        @compileError("VecN size must be >= 2");
    }

    return struct {
        inner: [size]T,

        pub fn from(values: [size]T) VecN(T, size) {
            return .{ .inner = values };
        }
        pub fn fromSliceAssertSize(values: []const T) VecN(T, size) {
            std.debug.assert(values.len == size);
            var inner: [size]T = undefined;
            std.mem.copyForwards(T, &inner, values);
            return .{ .inner = inner };
        }

        pub fn x(self: VecN(T, size)) T {
            return self.inner[0];
        }
        pub fn y(self: VecN(T, size)) T {
            return self.inner[1];
        }
        pub fn z(self: VecN(T, size)) T {
            return self.inner[2];
        }
        pub fn get(self: VecN(T, size), index: usize) T {
            return self.inner[index];
        }

        pub fn add(self: VecN(T, size), other: VecN(T, size)) VecN(T, size) {
            var new: [size]T = undefined;
            for (0..size) |i| {
                new[i] = self.inner[i] + other.inner[i];
            }
            return from(new);
        }
        pub fn sub(self: VecN(T, size), other: VecN(T, size)) VecN(T, size) {
            switch (@typeInfo(T)) {
                .Int => |info| {
                    if (info.signedness == std.builtin.Signedness.unsigned) {
                        @compileError("Operation 'sub' unsupported for unsigned int");
                    }
                },
                else => {},
            }
            var new: [size]T = undefined;
            for (0..size) |i| {
                new[i] = self.inner[i] - other.inner[i];
            }
            return from(new);
        }
        pub fn mul(self: VecN(T, size), scalar: T) VecN(T, size) {
            var new: [size]T = undefined;
            for (0..size) |i| {
                new[i] = self.inner[i] * scalar;
            }
            return from(new);
        }
        pub fn dot(self: VecN(T, size), other: VecN(T, size)) T {
            var product: T = 0;
            for (0..size) |i| {
                product += self.inner[i] * other.inner[i];
            }
            return product;
        }
    };
}

////////////////////////////////////////////////
const expectEqual = std.testing.expectEqual;
const expect = std.testing.expect;

test "Vec succeeds with number type" {
    _ = VecN(u8, 4);
    _ = VecN(i8, 4);
    _ = VecN(f16, 4);
}
test "Vec of different size or type are not equals" {
    const vu4 = VecN(u8, 4).from(.{ 1, 2, 3, 4 });
    const vu3 = VecN(u8, 3).from(.{ 1, 2, 3 });
    const vi4 = VecN(i8, 4).from(.{ -1, -2, -3, -4 });

    try expect(@TypeOf(vu4) != @TypeOf(vu3));
    try expect(@TypeOf(vi4) != @TypeOf(vu4));
}
test "Vec2 is same type as VecN(.., 2)" {
    const v2i = Vec2(i8);
    const vni = VecN(i8, 2);

    try expect(@TypeOf(v2i) == @TypeOf(vni));
}

test "Vec can be created from slice" {
    const array: [3]u8 = .{ 1, 2, 3 };
    const slice = array[0..];
    const v3 = Vec3(u8).fromSliceAssertSize(slice);

    try expectEqual(.{ 1, 2, 3 }, v3.inner);
}

test "Add with same size succeeds" {
    const v1 = VecN(i8, 3).from(.{ 1, 2, 3 });
    const v2 = VecN(i8, 3).from(.{ -1, -2, -3 });

    try expectEqual(.{ 0, 0, 0 }, v1.add(v2).inner);
}
test "sub with same size succeeds" {
    const v1 = VecN(f16, 3).from(.{ 1, 2, 3 });
    const v2 = VecN(f16, 3).from(.{ 1, 2, 3 });

    try expectEqual(.{ 0, 0, 0 }, v1.sub(v2).inner);
}
test "mul succeeds" {
    const v2f = Vec2(f16).from(.{ 1.1, 2.2 });
    const v3u = Vec3(u8).from(.{ 1, 2, 3 });

    try expectEqual(.{ -2.2, -4.4 }, v2f.mul(-2).inner);
    try expectEqual(.{ 2, 4, 6 }, v3u.mul(2).inner);
}
test "dot product succeeds" {
    const v3a = Vec3(i8).from(.{ 1, 3, -5 });
    const v3b = Vec3(i8).from(.{ 4, -2, -1 });

    try expectEqual(3, v3a.dot(v3b));
}
test "accessors succeed" {
    const v2 = Vec2(u8).from(.{ 1, 2 });
    const v3 = Vec3(f16).from(.{ 1, 2, 3.3 });
    const v5 = VecN(i8, 5).from(.{ -1, -2, -3, -4, -5 });

    try expectEqual(1, v2.x());
    try expectEqual(2, v2.y());
    try expectEqual(3.3, v3.z());
    try expectEqual(-5, v5.get(4));
}
