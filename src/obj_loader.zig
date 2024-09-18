const std = @import("std");
const math = @import("math.zig");
const utils = @import("parsing_utils.zig");

const LogLevel = std.log.Level;
const Vec2 = math.Vec2(f32);
const Vec3 = math.Vec3(f32);
const Vec4 = math.Vec4(f32);
const Vertex = Vec3;
const Uv = Vec2;
const Normal = Vec3;
const ArrayList = std.ArrayList;
const TokenIterator = utils.TokenIterator;
const ErrContext = utils.ErrContext;
const ParsingError = utils.ParsingError;

const ObjectsBuilder = struct {
    allocator: std.mem.Allocator,
    cur_obj: ?*MeshBuilder,
    objects: std.StringHashMap(MeshBuilder),
    global_vertex_info: VertexInfo,
    mtl_libs: ArrayList([]u8),

    fn init(allocator: std.mem.Allocator) ObjectsBuilder {
        return ObjectsBuilder{
            .allocator = allocator,
            .cur_obj = null,
            .objects = std.StringHashMap(MeshBuilder).init(allocator),
            .global_vertex_info = VertexInfo.init(allocator),
            .mtl_libs = ArrayList([]u8).init(allocator),
        };
    }
    fn deinit(self: *ObjectsBuilder) void {
        var obj_it = self.objects.valueIterator();
        while (obj_it.next()) |object| {
            object.deinit();
        }
        self.objects.deinit();
        self.global_vertex_info.deinit();
        for (self.mtl_libs.items) |lib| {
            self.allocator.free(lib);
        }
        self.mtl_libs.deinit();
    }

    fn switchCurObj(self: *ObjectsBuilder, obj_name: []const u8) !void {
        const entry = try self.objects.getOrPut(obj_name);
        if (!entry.found_existing) {
            entry.value_ptr.* = try MeshBuilder.init(obj_name, self.allocator);
        }
        self.cur_obj = entry.value_ptr;
    }

    fn addVertex(self: *ObjectsBuilder, vertex: Vertex) !void {
        if (self.cur_obj != null) {
            try self.cur_obj.?.addVertex(vertex);
        } else {
            try self.global_vertex_info.vertices.append(vertex);
        }
    }
    fn addUv(self: *ObjectsBuilder, uv: Uv) !void {
        if (self.cur_obj != null) {
            try self.cur_obj.?.addUv(uv);
        } else {
            try self.global_vertex_info.uvs.append(uv);
        }
    }
    fn addNormal(self: *ObjectsBuilder, normal: Normal) !void {
        if (self.cur_obj != null) {
            try self.cur_obj.?.addNormal(normal);
        } else {
            try self.global_vertex_info.normals.append(normal);
        }
    }

    fn addMtlLib(self: *ObjectsBuilder, lib: []const u8) !void {
        const lib_name = try self.allocator.alloc(u8, lib.len);
        std.mem.copyForwards(u8, lib_name, lib);
        try self.mtl_libs.append(lib_name);
    }
};

const VertexInfo = struct {
    vertices: ArrayList(Vertex),
    uvs: ArrayList(Uv),
    normals: ArrayList(Normal),

    fn init(allocator: std.mem.Allocator) VertexInfo {
        return VertexInfo{
            .vertices = ArrayList(Vec3).init(allocator),
            .uvs = ArrayList(Vec2).init(allocator),
            .normals = ArrayList(Vec3).init(allocator),
        };
    }

    fn deinit(self: *VertexInfo) void {
        self.vertices.deinit();
        self.uvs.deinit();
        self.normals.deinit();
    }
};

const Face = struct {
    allocator: std.mem.Allocator,
    vertex_indices: ArrayList(u32),
    uv_indices: ArrayList(u32),
    normal_indices: ArrayList(u32),
    material: ArrayList(u8),

    fn init(allocator: std.mem.Allocator) Face {
        return Face{
            .allocator = allocator,
            .vertex_indices = ArrayList(u32).init(allocator),
            .uv_indices = ArrayList(u32).init(allocator),
            .normal_indices = ArrayList(u32).init(allocator),
            .material = ArrayList(u8).init(allocator),
        };
    }
    fn deinit(self: *Face) void {
        self.vertex_indices.deinit();
        self.uv_indices.deinit();
        self.normal_indices.deinit();
        self.material.deinit();
    }

    fn setMaterial(self: *Face, name: []const u8) !void {
        self.material.clearRetainingCapacity();
        try self.material.appendSlice(name);
    }
};

const MeshBuilder = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    vertex_info: ?VertexInfo,
    faces: ArrayList(Face),

    fn init(object_name: []const u8, allocator: std.mem.Allocator) !MeshBuilder {
        const name = try allocator.alloc(u8, object_name.len);
        std.mem.copyForwards(u8, name, object_name);
        return MeshBuilder{
            .name = name,
            .allocator = allocator,
            .vertex_info = null,
            .faces = ArrayList(Face).init(allocator),
        };
    }
    fn deinit(self: *MeshBuilder) void {
        self.allocator.free(self.name);
        if (self.vertex_info != null) self.vertex_info.?.deinit();
        for (self.faces.items) |*face| {
            face.deinit();
        }
        self.faces.deinit();
    }

    fn addVertex(self: *MeshBuilder, vertex: Vertex) !void {
        if (self.vertex_info == null) self.vertex_info = VertexInfo.init(self.allocator);
        try self.vertex_info.?.vertices.append(vertex);
    }
    fn addUv(self: *MeshBuilder, uv: Uv) !void {
        if (self.vertex_info == null) self.vertex_info = VertexInfo.init(self.allocator);
        try self.vertex_info.?.uvs.append(uv);
    }
    fn addNormal(self: *MeshBuilder, normal: Normal) !void {
        if (self.vertex_info == null) self.vertex_info = VertexInfo.init(self.allocator);
        try self.vertex_info.?.normals.append(normal);
    }
};

pub fn parseObjFile(file: anytype, file_name: []const u8, comptime allocator: std.mem.Allocator) !ObjectsBuilder {
    var builder = ObjectsBuilder.init(allocator);
    errdefer builder.deinit();
    var err_ctx = ErrContext{ .file_name = file_name, .line = 1 };

    //    const stream = std.io.bufferedReader(file.reader()).reader();
    var buf: [100_000]u8 = undefined;
    var cur_mtl = ArrayList(u8).init(allocator);
    defer cur_mtl.deinit();

    while (try file.readUntilDelimiterOrEof(&buf, '\n')) |line| : (err_ctx.line += 1) {
        var token_it = std.mem.tokenizeAny(u8, line, " \t\r");
        const id = token_it.next() orelse continue;

        if (std.mem.eql(u8, id, "#")) {
            continue;
        } else if (std.mem.eql(u8, id, "v")) {
            const vertex = try parseVertex(&token_it, err_ctx, allocator);
            try builder.addVertex(vertex);
        } else if (std.mem.eql(u8, id, "vn")) {
            const normal = try parseNormal(&token_it, err_ctx, allocator);
            try builder.addNormal(normal);
        } else if (std.mem.eql(u8, id, "vt")) {
            const uv = try parseUv(&token_it, err_ctx, allocator);
            try builder.addUv(uv);
        } else if (std.mem.eql(u8, id, "f")) {
            var face = try parseFace(&token_it, err_ctx, allocator);
            if (cur_mtl.items.len > 0) try face.setMaterial(cur_mtl.items);
            if (builder.cur_obj == null) try builder.switchCurObj("object_default");
            try builder.cur_obj.?.faces.append(face);
        } else if (std.mem.eql(u8, id, "o")) {
            const object_name = token_it.next() orelse {
                utils.log(.obj_loader, LogLevel.err, err_ctx, "Object entry does not contain any name", .{});
                return ParsingError.invalidEntry;
            };
            try builder.switchCurObj(object_name);
        } else if (std.mem.eql(u8, id, "mtllib")) {
            while (token_it.next()) |lib_name| {
                try builder.addMtlLib(lib_name);
            }
        } else if (std.mem.eql(u8, id, "usemtl")) {
            const material = token_it.next() orelse {
                utils.log(.obj_loader, LogLevel.err, err_ctx, "Use material entry does not contain any name", .{});
                return ParsingError.invalidEntry;
            };
            cur_mtl.clearRetainingCapacity();
            try cur_mtl.appendSlice(material);
        } else {
            utils.log(.obj_loader, LogLevel.warn, err_ctx, "tag not supported '{s}', skipping line ({s})", .{ id, line });
            continue;
        }
    }

    return builder;
}

fn parseVertex(tokens: *TokenIterator, ctx: ErrContext, allocator: std.mem.Allocator) !Vec3 {
    var values: [3]f32 = undefined;
    const parsed_values = try utils.parseValues(tokens, ctx, allocator);
    defer parsed_values.deinit();

    switch (parsed_values.items.len) {
        3 => {},
        4 => {
            utils.log(.obj_loader, LogLevel.warn, ctx, "ignoring vertex value w '{d}'", .{parsed_values.getLast()});
        },
        else => {
            utils.log(.obj_loader, LogLevel.err, ctx, "invalid line entry for vertex: expected 3(4) values found {d}", .{parsed_values.items.len});
            return ParsingError.invalidEntry;
        },
    }

    std.mem.copyForwards(f32, &values, parsed_values.items[0..3]);
    return Vec3.from(values);
}

fn parseUv(tokens: *TokenIterator, ctx: ErrContext, allocator: std.mem.Allocator) !Vec2 {
    var values: [2]f32 = undefined;
    const parsed_values = try utils.parseValues(tokens, ctx, allocator);
    defer parsed_values.deinit();

    switch (parsed_values.items.len) {
        2 => {},
        3 => {
            utils.log(.obj_loader, LogLevel.warn, ctx, "ignoring texture value w '{d}'", .{parsed_values.getLast()});
        },
        else => {
            utils.log(.obj_loader, LogLevel.err, ctx, "invalid line entry for texture: expected 2(3) values found {d}", .{parsed_values.items.len});
            return ParsingError.invalidEntry;
        },
    }

    std.mem.copyForwards(f32, &values, parsed_values.items[0..2]);
    return Vec2.from(values);
}

fn parseNormal(tokens: *TokenIterator, ctx: ErrContext, allocator: std.mem.Allocator) !Vec3 {
    var values: [3]f32 = undefined;
    const parsed_values = try utils.parseValues(tokens, ctx, allocator);
    defer parsed_values.deinit();

    if (parsed_values.items.len != 3) {
        utils.log(.obj_loader, LogLevel.err, ctx, "invalid line entry for normal: expected 3 values found {d}", .{parsed_values.items.len});
        return ParsingError.invalidEntry;
    }

    std.mem.copyForwards(f32, &values, parsed_values.items[0..3]);
    return Vec3.from(values);
}

fn parseFace(tokens: *TokenIterator, ctx: ErrContext, allocator: std.mem.Allocator) !Face {
    var face = Face.init(allocator);
    errdefer face.deinit();

    while (tokens.next()) |token| {
        try parseIndicesGroup(token, &face, ctx);
    }
    const vertex_len = face.vertex_indices.items.len;
    const uv_len = face.uv_indices.items.len;
    const normal_len = face.normal_indices.items.len;
    if (vertex_len < 3) {
        utils.log(.obj_loader, LogLevel.err, ctx, "Face must contain at least 3 vertices, found {d}", .{vertex_len});
        return ParsingError.invalidEntry;
    }
    if (uv_len != 0 and uv_len != vertex_len) {
        utils.log(.obj_loader, LogLevel.err, ctx, "Size of non-empty uv indices do not match vertex_indices: expected {d} found {d}", .{ vertex_len, uv_len });
        return ParsingError.invalidEntry;
    }
    if (normal_len != 0 and normal_len != vertex_len) {
        utils.log(.obj_loader, LogLevel.err, ctx, "Size of non-empty normal indices do not match vertex_indices: expected {d} found {d}", .{ vertex_len, normal_len });
        return ParsingError.invalidEntry;
    }

    return face;
}

fn parseIndicesGroup(indices: []const u8, face: *Face, ctx: ErrContext) !void {
    var it = std.mem.splitScalar(u8, indices, '/');
    var count: u8 = 0;
    while (it.next()) |index| : (count += 1) {
        if (index.len == 0) continue;
        const i = std.fmt.parseInt(u32, index, 10) catch |e| {
            utils.log(.obj_loader, LogLevel.err, ctx, "failed to parse face indices '{s}' at '{s}': {}", .{ indices, index, e });
            return ParsingError.invalidToken;
        };
        switch (count) {
            0 => try face.vertex_indices.append(i),
            1 => try face.uv_indices.append(i),
            2 => try face.normal_indices.append(i),
            else => {
                utils.log(.obj_loader, LogLevel.err, ctx, "invalid indices token '{s}'", .{indices});
                return ParsingError.invalidToken;
            },
        }
    }
}

/////////////////////////////////////////
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;
const expectEqualSlice = std.testing.expectEqualSlices;

// test vertex

test "parse vertex succeeds with 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345  ", " \t");
    const ctx = ErrContext{ .file_name = "test_vertex", .line = 1 };

    const vertex = try parseVertex(&token_it, ctx, std.testing.allocator);

    try expectEqual(Vec3, @TypeOf(vertex));
    try expectEqual(.{ 0.123, 0.234, 0.345 }, vertex.inner);
}

test "parse vertex succeeds with 4 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345 0.456 ", " \t");
    const ctx = ErrContext{ .file_name = "test_vertex", .line = 1 };

    const vertex = try parseVertex(&token_it, ctx, std.testing.allocator);

    try expectEqual(Vec3, @TypeOf(vertex));
    try expectEqual(.{ 0.123, 0.234, 0.345 }, vertex.inner);
}

test "parse vertex fails with less than 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, "", " \t");
    const ctx = ErrContext{ .file_name = "test_vertex", .line = 1 };

    const ret = parseVertex(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

test "parse vertex fails with more than 4 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345 1.987 1.654 ", " \t");
    const ctx = ErrContext{ .file_name = "test_vertex", .line = 1 };

    const ret = parseVertex(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

// test uv

test "parse uv succeeds with 2 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  ", " \t");
    const ctx = ErrContext{ .file_name = "test_uv", .line = 1 };

    const uv = try parseUv(&token_it, ctx, std.testing.allocator);

    try expectEqual(Vec2, @TypeOf(uv));
    try expectEqual(.{ 0.123, 0.234 }, uv.inner);
}

test "parse uv succeeds with 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345 ", " \t");
    const ctx = ErrContext{ .file_name = "test_uv", .line = 1 };

    const uv = try parseUv(&token_it, ctx, std.testing.allocator);

    try expectEqual(Vec2, @TypeOf(uv));
    try expectEqual(.{ 0.123, 0.234 }, uv.inner);
}

test "parse uv fails with less than 2 floats" {
    var token_it = std.mem.tokenizeAny(u8, "", " \t");
    const ctx = ErrContext{ .file_name = "test_uv", .line = 1 };

    const ret = parseUv(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

test "parse uv fails with more than 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345 1.987 1.654 ", " \t");
    const ctx = ErrContext{ .file_name = "test_uv", .line = 1 };

    const ret = parseUv(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

// test normals

test "parse normal succeeds with 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345  ", " \t");
    const ctx = ErrContext{ .file_name = "test_normal", .line = 1 };

    const normal = try parseNormal(&token_it, ctx, std.testing.allocator);

    try expectEqual(Vec3, @TypeOf(normal));
    try expectEqual(.{ 0.123, 0.234, 0.345 }, normal.inner);
}

test "parse normal fails with less than 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, "", " \t");
    const ctx = ErrContext{ .file_name = "test_normal", .line = 1 };

    const ret = parseNormal(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

test "parse normal fails with more than 3 floats" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345 1.987 1.654 ", " \t");
    const ctx = ErrContext{ .file_name = "test_normal", .line = 1 };

    const ret = parseNormal(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

// test face

test "parse face succeed with vertex indices only" {
    var token_it = std.mem.tokenizeAny(u8, " 1 5 24 ", " \t");
    const ctx = ErrContext{ .file_name = "test_face", .line = 1 };

    var face = try parseFace(&token_it, ctx, std.testing.allocator);
    defer face.deinit();

    const expected: [3]u32 = .{ 1, 5, 24 };

    try expectEqualSlice(u32, expected[0..3], face.vertex_indices.items);
    try expectEqual(0, face.normal_indices.items.len);
    try expectEqual(0, face.uv_indices.items.len);
}

test "parse face succeed with vertex indices only followed by /" {
    var token_it = std.mem.tokenizeAny(u8, " 1// 5// 24// ", " \t");
    const ctx = ErrContext{ .file_name = "test_face", .line = 1 };

    var face = try parseFace(&token_it, ctx, std.testing.allocator);
    defer face.deinit();
    const expected: [3]u32 = .{ 1, 5, 24 };

    try expectEqualSlice(u32, expected[0..3], face.vertex_indices.items);
    try expectEqual(0, face.normal_indices.items.len);
    try expectEqual(0, face.uv_indices.items.len);
}

test "parse face succeed with vertex and uv indices" {
    var token_it = std.mem.tokenizeAny(u8, " 1/2 5/6 24/25 ", " \t");
    const ctx = ErrContext{ .file_name = "test_face", .line = 1 };

    var face = try parseFace(&token_it, ctx, std.testing.allocator);
    defer face.deinit();

    const expected_vertex: [3]u32 = .{ 1, 5, 24 };
    const expected_uv: [3]u32 = .{ 2, 6, 25 };

    try expectEqualSlice(u32, expected_vertex[0..3], face.vertex_indices.items);
    try expectEqual(0, face.normal_indices.items.len);
    try expectEqualSlice(u32, expected_uv[0..3], face.uv_indices.items);
}

test "parse face succeed with vertex and normal indices" {
    var token_it = std.mem.tokenizeAny(u8, " 1//2 5//6 24//25 ", " \t");
    const ctx = ErrContext{ .file_name = "test_face", .line = 1 };

    var face = try parseFace(&token_it, ctx, std.testing.allocator);
    defer face.deinit();

    const expected_vertex: [3]u32 = .{ 1, 5, 24 };
    const expected_normal: [3]u32 = .{ 2, 6, 25 };

    try expectEqualSlice(u32, expected_vertex[0..3], face.vertex_indices.items);
    try expectEqual(0, face.uv_indices.items.len);
    try expectEqualSlice(u32, expected_normal[0..3], face.normal_indices.items);
}

test "parse face succeed with all indices" {
    var token_it = std.mem.tokenizeAny(u8, " 1/2/3 5/6/7 24/25/26 ", " \t");
    const ctx = ErrContext{ .file_name = "test_face", .line = 1 };

    var face = try parseFace(&token_it, ctx, std.testing.allocator);
    defer face.deinit();

    const expected_vertex: [3]u32 = .{ 1, 5, 24 };
    const expected_uv: [3]u32 = .{ 2, 6, 25 };
    const expected_normal: [3]u32 = .{ 3, 7, 26 };

    try expectEqualSlice(u32, expected_vertex[0..3], face.vertex_indices.items);
    try expectEqualSlice(u32, expected_uv[0..3], face.uv_indices.items);
    try expectEqualSlice(u32, expected_normal[0..3], face.normal_indices.items);
}

test "parse face fails with different amount of indices" {
    var token_it = std.mem.tokenizeAny(u8, " 1/3/2 5//6 24//25 ", " \t");
    const ctx = ErrContext{ .file_name = "test_face", .line = 1 };

    const ret = parseFace(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

test "parse face fails if less than 3 vertex provided" {
    var token_it = std.mem.tokenizeAny(u8, "1// /5/ //25 ", " \t");
    const ctx = ErrContext{ .file_name = "test_face", .line = 1 };

    const ret = parseFace(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidEntry, ret);
}

// Full Object Parser

test "object parser succeed on valid input" {
    const file =
        \\ # Test object file basic
        \\ o test_object
        \\ v 0.000000 0.000000 -1.500000
        \\ v -1.500000 0.000000 0.000000
        \\ v 0.000000 1.500000 0.000000
        \\ v 0.000000 0.000000 1.500000
        \\
        \\ vn 0.000000 0.000000 -1.000000
        \\ vt 0.000000 0.000000
        \\ mtllib test_lib
        \\ usemtl test_mtl_1
        \\ f 1/1/1 2/1/1 3/1/1
        \\ usemtl test_mtl_2
        \\ f 2/1/1 3/1/1 4/1/1
    ;
    var fbs = std.io.fixedBufferStream(file);

    var builder = try parseObjFile(fbs.reader(), "test_file", std.testing.allocator);
    defer builder.deinit();

    try expectEqual(1, builder.objects.count());
    const object = builder.cur_obj.?;
    try expectEqualSlice(u8, "test_object", object.name);
    try expectEqual(4, object.vertex_info.?.vertices.items.len);
    try expectEqual(.{ 0.0, 0.0, -1.0 }, object.vertex_info.?.normals.items[0].inner);
    try expectEqual(.{ 0.0, 0.0 }, object.vertex_info.?.uvs.items[0].inner);
    const face_1 = object.faces.items[0];
    const face_2 = object.faces.items[1];
    try expectEqualSlice(u8, "test_mtl_1", face_1.material.items);
    try expectEqualSlice(u8, "test_mtl_2", face_2.material.items);
}
