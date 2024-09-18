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

pub fn parseValues(tokens: *TokenIterator, ctx: ErrContext, allocator: std.mem.Allocator) !std.ArrayList(f32) {
    var values = std.ArrayList(f32).init(allocator);
    errdefer values.deinit();

    while (tokens.next()) |token| {
        const value = std.fmt.parseFloat(f32, token) catch |e| {
            log(.parsing_utils, std.log.Level.err, ctx, "failed to parse token '{s}' as float: {}", .{ token, e });
            return ParsingError.invalidToken;
        };
        try values.append(value);
    }

    return values;
}

pub fn log(comptime scope: @TypeOf(.enum_literal), comptime level: std.log.Level, context: ErrContext, comptime msg: []const u8, args: anytype) void {
    const logger = std.log.scoped(scope);
    switch (level) {
        .debug => logger.debug("{s} (line {d}): " ++ msg, .{ context.file_name, context.line } ++ args),
        .info => logger.info("{s} (line {d}): " ++ msg, .{ context.file_name, context.line } ++ args),
        .warn => logger.warn("{s} (line {d}): " ++ msg, .{ context.file_name, context.line } ++ args),
        .err => logger.err("{s} (line {d}): " ++ msg, .{ context.file_name, context.line } ++ args),
    }
}
