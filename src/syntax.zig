const std = @import("std");
const ts = @import("tree-sitter");

const Self = @This();

pub const Edit = ts.InputEdit;
pub const FileType = @import("file_type.zig");
pub const Range = ts.Range;

a: std.mem.Allocator,
lang: *const ts.Language,
file_type: *const FileType,
parser: *ts.Parser,
query: *ts.Query,
injections: *ts.Query,
tree: ?*ts.Tree = null,
content: []const u8,

pub fn create(file_type: *const FileType, a: std.mem.Allocator, content: []const u8) !*Self {
    const self = try a.create(Self);
    self.* = .{
        .a = a,
        .lang = file_type.lang_fn() orelse std.debug.panic("tree-sitter parser function failed for language: {d}", .{file_type.name}),
        .file_type = file_type,
        .parser = try ts.Parser.create(),
        .query = try ts.Query.create(self.lang, file_type.highlights),
        .injections = try ts.Query.create(self.lang, file_type.highlights),
        .content = content,
    };
    errdefer self.destroy();
    try self.parser.setLanguage(self.lang);
    try self.parse();
    return self;
}

pub fn create_file_type(a: std.mem.Allocator, content: []const u8, lang_name: []const u8) !*Self {
    const file_type = FileType.get_by_name(lang_name) orelse return error.NotFound;
    return create(file_type, a, content);
}

pub fn create_guess_file_type(a: std.mem.Allocator, content: []const u8, file_path: ?[]const u8) !*Self {
    const file_type = FileType.guess(file_path, content) orelse return error.NotFound;
    return create(file_type, a, content);
}

pub fn destroy(self: *Self) void {
    if (self.tree) |tree| tree.destroy();
    self.query.destroy();
    self.parser.destroy();
    self.a.destroy(self);
}

fn parse(self: *Self) !void {
    if (self.tree) |tree| tree.destroy();
    self.tree = try self.parser.parseString(null, self.content);
}

fn CallBack(comptime T: type) type {
    return fn (ctx: T, sel: Range, scope: []const u8, id: u32, idx: usize) error{Stop}!void;
}

pub fn render(self: *const Self, ctx: anytype, comptime cb: CallBack(@TypeOf(ctx))) !void {
    const cursor = try ts.Query.Cursor.create();
    defer cursor.destroy();
    const tree = if (self.tree) |p| p else return;
    cursor.execute(self.query, tree.getRootNode());
    while (cursor.nextMatch()) |match| {
        var idx: usize = 0;
        for (match.captures()) |capture| {
            const range = capture.node.getRange();
            const scope = self.query.getCaptureNameForId(capture.id);
            try cb(ctx, range, scope, capture.id, idx);
            idx += 1;
        }
    }
}
