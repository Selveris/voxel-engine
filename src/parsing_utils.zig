const std = @import("std");

pub const TokenIterator = std.mem.TokenIterator(u8, .any);

pub const ParsingError = error{
    invalidToken,
    invalidEntry,
};

pub const ErrContext = struct {
    file_name: []const u8,
    line: usize,
};

fn parseFloat(token: []const u8, ctx: ErrContext) !f32 {
    return std.fmt.parseFloat(f32, token) catch |e| {
        log(.parsing_utils, std.log.Level.err, ctx, "failed to parse token '{s}' as float: {}", .{ token, e });
        return ParsingError.invalidToken;
    };
}

pub fn parseValue(tokens: *TokenIterator, ctx: ErrContext) !f32 {
    const token = tokens.next() orelse {
        log(.parsing_utils, std.log.Level.err, ctx, "failed to parse value, no token found", .{});
        return ParsingError.invalidEntry;
    };

    return try parseFloat(token, ctx);
}

pub fn parseValues(tokens: *TokenIterator, ctx: ErrContext, allocator: std.mem.Allocator) !std.ArrayList(f32) {
    var values = std.ArrayList(f32).init(allocator);
    errdefer values.deinit();

    while (tokens.next()) |token| {
        const value = try parseFloat(token, ctx);
        try values.append(value);
    }

    return values;
}

pub fn log(comptime scope: @TypeOf(.enum_literal), comptime level: std.log.Level, context: ErrContext, comptime msg: []const u8, args: anytype) void {
    if (!@import("builtin").is_test) {
        const logger = std.log.scoped(scope);
        switch (level) {
            .debug => logger.debug("{s} (line {d}): " ++ msg, .{ context.file_name, context.line } ++ args),
            .info => logger.info("{s} (line {d}): " ++ msg, .{ context.file_name, context.line } ++ args),
            .warn => logger.warn("{s} (line {d}): " ++ msg, .{ context.file_name, context.line } ++ args),
            .err => logger.err("{s} (line {d}): " ++ msg, .{ context.file_name, context.line } ++ args),
        }
    }
}

/////////////////////////////////////////
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

// value

test "parse value fails on non floats token" {
    var token_it = std.mem.tokenizeAny(u8, " \t0.3a45  ", " \t");
    const ctx = ErrContext{ .file_name = "test_value", .line = 1 };

    const ret = parseValue(&token_it, ctx);

    try expectError(ParsingError.invalidToken, ret);
}

test "parse value fails on empty token" {
    var token_it = std.mem.tokenizeAny(u8, " \t  ", " \t");
    const ctx = ErrContext{ .file_name = "test_value", .line = 1 };

    const ret = parseValue(&token_it, ctx);

    try expectError(ParsingError.invalidEntry, ret);
}

test "parse value succeeds on valid entry" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345 \t 0.000 -0.987 ", " \t");
    const ctx = ErrContext{ .file_name = "test_value", .line = 1 };

    const ret = try parseValue(&token_it, ctx);

    try std.testing.expectEqual(0.123, ret);
}

// values

test "parse multiple values fails on non floats token" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.3a45  ", " \t");
    const ctx = ErrContext{ .file_name = "test_values", .line = 1 };

    const ret = parseValues(&token_it, ctx, std.testing.allocator);

    try expectError(ParsingError.invalidToken, ret);
}

test "parse multiple values succeeds on valid entry" {
    var token_it = std.mem.tokenizeAny(u8, " 0.123 \t 0.234  0.345 \t 0.000 -0.987 ", " \t");
    const ctx = ErrContext{ .file_name = "test_values", .line = 1 };

    const ret = try parseValues(&token_it, ctx, std.testing.allocator);
    defer ret.deinit();

    const expected: [5]f32 = .{ 0.123, 0.234, 0.345, 0.000, -0.987 };
    try std.testing.expectEqualSlices(f32, expected[0..], ret.items);
}
