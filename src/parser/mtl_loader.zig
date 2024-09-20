const std = @import("std");
const math = @import("math.zig");
const utils = @import("parsing_utils.zig");

const Allocator = std.mem.Allocator;
const LogLevel = std.log.Level;
const Vec3 = math.Vec3(f32);
const ParsingError = utils.ParsingError;
const ErrContext = utils.ErrContext;
const TokenIterator = utils.TokenIterator;

const MtlLibBuilder = struct {
    allocator: Allocator,
    materials: std.StringHashMap(MaterialBuilder),

    fn init(allocator: Allocator) MtlLibBuilder {
        return MtlLibBuilder{
            .allocator = allocator,
            .materials = std.StringHashMap(MaterialBuilder).init(allocator),
        };
    }
    fn deinit(self: *MtlLibBuilder) void {
        var materials = self.materials.valueIterator();
        while (materials.next()) |material| {
            material.deinit();
        }
        self.materials.deinit();
    }

    fn switchMtl(self: *MtlLibBuilder, mtl_name: []const u8) !*MaterialBuilder {
        const gop = try self.materials.getOrPut(mtl_name);
        if (!gop.found_existing) {
            gop.value_ptr.* = try MaterialBuilder.init(mtl_name, self.allocator);
            gop.key_ptr.* = gop.value_ptr.name;
        }
        return gop.value_ptr;
    }
};

const MaterialBuilder = struct {
    allocator: Allocator,
    name: []u8,
    ambiant: ?Vec3,
    diffuse: ?Vec3,
    specular: ?Vec3,
    highlights: ?f32,
    density: ?f32,
    dissolve: ?f32,
    illum: ?u8,
    texture: ?[]u8,

    fn init(name: []const u8, allocator: Allocator) !MaterialBuilder {
        const n = try allocator.alloc(u8, name.len);
        std.mem.copyForwards(u8, n, name);
        return MaterialBuilder{
            .allocator = allocator,
            .name = n,
            .ambiant = null,
            .diffuse = null,
            .specular = null,
            .highlights = null,
            .density = null,
            .dissolve = null,
            .illum = null,
            .texture = null,
        };
    }
    fn deinit(self: *MaterialBuilder) void {
        self.allocator.free(self.name);
        if (self.texture != null) self.allocator.free(self.texture.?);
    }

    fn addTextureAssertNull(self: *MaterialBuilder, texture_name: []const u8) !void {
        std.debug.assert(self.texture == null);
        const texture = try self.allocator.alloc(texture_name.len);
        std.mem.copyForwards(u8, texture, texture_name);
        self.texture = texture;
    }
};

pub fn parseMtlFile(file: anytype, file_name: []const u8, comptime allocator: std.mem.Allocator) !MtlLibBuilder {
    var builder = MtlLibBuilder.init(allocator);
    errdefer builder.deinit();
    var err_ctx = ErrContext{ .file_name = file_name, .line = 1 };

    var buf: [100_000]u8 = undefined;
    var cur_mtl: ?*MaterialBuilder = null;

    while (try file.readUntilDelimiterOrEof(&buf, '\n')) |line| : (err_ctx.line += 1) {
        var token_it = std.mem.tokenizeAny(u8, line, " \t\r");
        const tag = token_it.next() orelse continue;

        if (std.mem.eql(u8, tag, "#")) {
            continue;
        } else if (std.mem.eql(u8, tag, "newmtl")) {
            const mtl_name = token_it.next() orelse {
                utils.log(.mtl_loader, LogLevel.err, err_ctx, "New material entry does not contain any name", .{});
                return ParsingError.invalidEntry;
            };
            cur_mtl = try builder.switchMtl(mtl_name);
        } else if (std.mem.eql(u8, tag, "Ka")) {
            const mtl = try assertMtlExist(cur_mtl, err_ctx, tag);
            mtl.ambiant = try parseColor(&token_it, tag, err_ctx, allocator);
        } else if (std.mem.eql(u8, tag, "Kd")) {
            const mtl = try assertMtlExist(cur_mtl, err_ctx, tag);
            mtl.diffuse = try parseColor(&token_it, tag, err_ctx, allocator);
        } else if (std.mem.eql(u8, tag, "Ks")) {
            const mtl = try assertMtlExist(cur_mtl, err_ctx, tag);
            mtl.specular = try parseColor(&token_it, tag, err_ctx, allocator);
        } else if (std.mem.eql(u8, tag, "Ns")) {
            const mtl = try assertMtlExist(cur_mtl, err_ctx, tag);
            mtl.highlights = try utils.parseValue(&token_it, err_ctx);
        } else if (std.mem.eql(u8, tag, "Ni")) {
            const mtl = try assertMtlExist(cur_mtl, err_ctx, tag);
            mtl.density = try utils.parseValue(&token_it, err_ctx);
        } else if (std.mem.eql(u8, tag, "d")) {
            const mtl = try assertMtlExist(cur_mtl, err_ctx, tag);
            mtl.dissolve = try utils.parseValue(&token_it, err_ctx);
        } else if (std.mem.eql(u8, tag, "map_Kd")) {
            const mtl = try assertMtlExist(cur_mtl, err_ctx, tag);
            const texture_name = token_it.next() orelse {
                utils.log(.mtl_loader, LogLevel.err, err_ctx, "texture entry does not contain any name", .{});
                return ParsingError.invalidEntry;
            };
            const name = try allocator.alloc(u8, texture_name.len);
            std.mem.copyForwards(u8, name, texture_name);
            mtl.texture = name;
        } else {
            utils.log(.mtl_loader, LogLevel.warn, err_ctx, "tag not supported '{s}', skipping line ({s})", .{ tag, line });
            continue;
        }
    }

    return builder;
}

fn assertMtlExist(mtl: ?*MaterialBuilder, ctx: ErrContext, tag: []const u8) !*MaterialBuilder {
    if (mtl == null) {
        utils.log(.mtl_loader, LogLevel.err, ctx, "failed to add property '{s}', material as it has not been set", .{tag});
        return ParsingError.invalidEntry;
    }
    return mtl.?;
}

fn parseColor(tokens: *TokenIterator, tag: []const u8, ctx: ErrContext, allocator: Allocator) !Vec3 {
    const color = try utils.parseValues(tokens, ctx, allocator);
    defer color.deinit();
    if (color.items.len != 3) {
        utils.log(.mtl_loader, LogLevel.err, ctx, "{s} color size must be 3, found {d}", .{ tag, color.items.len });
        return ParsingError.invalidEntry;
    }
    return Vec3.fromSliceAssertSize(color.items);
}

/////////////////////////////////////////
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlice = std.testing.expectEqualSlices;

// Color
test "parse color succeeds with 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345  ", " \t");
    const ctx = ErrContext{ .file_name = "test_color", .line = 1 };

    const color = try parseColor(&token_it, "test", ctx, std.testing.allocator);

    try expectEqual(Vec3, @TypeOf(color));
    try expectEqual(.{ 0.123, 0.234, 0.345 }, color.inner);
}

test "parse color fails with less than 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, "", " \t");
    const ctx = ErrContext{ .file_name = "test_color", .line = 1 };

    const ret = parseColor(&token_it, "test", ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

test "parse color fails with more than 4 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345 1.987 1.654 ", " \t");
    const ctx = ErrContext{ .file_name = "test_color", .line = 1 };

    const ret = parseColor(&token_it, "test", ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

// Full Parser
test "object parser succeed on valid input" {
    const file =
        \\ # Material Count: 1
        \\
        \\ newmtl Material
        \\ Ns 96.078431
        \\ Ka 0.000000 0.000000 0.000000
        \\ Kd 0.640000 0.640000 0.640000
        \\ Ks 0.500000 0.500000 0.500000
        \\ Ni 1.000000
        \\ d 1.000000
        \\ illum 2
    ;
    var fbs = std.io.fixedBufferStream(file);

    var builder = try parseMtlFile(fbs.reader(), "test_file", std.testing.allocator);
    defer builder.deinit();

    try expectEqual(1, builder.materials.count());
    try std.testing.expect(builder.materials.get("Material") != null);
    const mtl = builder.materials.get("Material").?;

    try expectEqualSlice(u8, "Material", mtl.name);
    try expectEqual(.{ 0.0, 0.0, 0.0 }, mtl.ambiant.?.inner);
    try expectEqual(.{ 0.64, 0.64, 0.64 }, mtl.diffuse.?.inner);
    try expectEqual(.{ 0.5, 0.5, 0.5 }, mtl.specular.?.inner);
    try expectEqual(96.078431, mtl.highlights);
    try expectEqual(1.0, mtl.density);
    try expectEqual(1.0, mtl.dissolve);
}
