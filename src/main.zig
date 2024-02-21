const std = @import("std");
const clap = @import("clap");
const syntax = @import("syntax");
const Theme = @import("theme");
const themes = @import("themes");
const term = @import("ansi-term.zig");
const config_loader = @import("config_loader.zig");

const StyleCache = std.AutoHashMap(u32, ?Theme.Token);
var style_cache: StyleCache = undefined;
var lang_override: ?[]const u8 = null;
var lang_default: []const u8 = "conf";

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-l, --language <str>     Override the language.
        \\-t, --theme <str>        Select theme to use.
        \\-d, --default <str>      Set the language to use if guessing failed (default: conf).
        \\-s, --show-language      Show detected language in output.
        \\--list-themes            Show available themes.
        \\--list-languages         Show available language parsers.
        \\<str>...                 File to open.
        \\
    );

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const a = gpa.allocator();
    style_cache = StyleCache.init(a);

    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, clap.parsers.default, .{
        .diagnostic = &diag,
        .allocator = a,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{}) catch {};
        std.os.exit(1);
        return err;
    };
    defer res.deinit();

    if (res.args.help != 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

    if (res.args.@"list-themes" != 0)
        return list_themes(std.io.getStdOut().writer());

    if (res.args.@"list-languages" != 0)
        return list_langs(std.io.getStdOut().writer());

    var conf_buf: ?[]const u8 = null;
    const conf = config_loader.read_config(a, &conf_buf);
    const theme_name = if (res.args.theme) |theme| theme else conf.theme;

    const theme = get_theme_by_name(theme_name) orelse {
        try std.io.getStdErr().writer().print("theme \"{s}\" not found\n", .{theme_name});
        std.os.exit(1);
    };

    lang_override = res.args.language;
    if (res.args.default) |default| lang_default = default;

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const writer = bw.writer();

    if (res.positionals.len > 0) {
        for (res.positionals) |arg| {
            const file = try std.fs.cwd().openFile(arg, .{ .mode = .read_only });
            defer file.close();
            const content = try file.readToEndAlloc(a, std.math.maxInt(u32));
            defer a.free(content);
            render_file(a, writer, content, arg, &theme, res.args.@"show-language" != 0) catch |e| switch (e) {
                error.Stop => return,
                else => return e,
            };
            try bw.flush();
        }
    } else {
        const content = try std.io.getStdIn().readToEndAlloc(a, std.math.maxInt(u32));
        defer a.free(content);
        render_file(a, writer, content, "-", &theme, res.args.@"show-language" != 0) catch |e| switch (e) {
            error.Stop => return,
            else => return e,
        };
    }
    try bw.flush();
}

fn get_parser(a: std.mem.Allocator, content: []const u8, file_path: []const u8) *syntax {
    return (if (lang_override) |name|
        syntax.create_file_type(a, content, name) catch unknown_file_type(name)
    else
        syntax.create_guess_file_type(a, content, file_path)) catch syntax.create_file_type(a, content, lang_default) catch unknown_file_type(lang_default);
}

fn unknown_file_type(name: []const u8) noreturn {
    std.io.getStdErr().writer().print("unknown file type \'{s}\'\n", .{name}) catch {};
    std.os.exit(1);
}

fn render_file(a: std.mem.Allocator, writer: anytype, content: []const u8, file_path: []const u8, theme: *const Theme, show: bool) !void {
    const parser = get_parser(a, content, file_path);
    if (show) try render_file_type(writer, parser.file_type, theme);

    const Ctx = struct {
        writer: @TypeOf(writer),
        content: []const u8,
        theme: *const Theme,
        last_pos: usize = 0,
        fn cb(ctx: *@This(), range: syntax.Range, scope: []const u8, id: u32, idx: usize) error{Stop}!void {
            if (idx > 0) return;

            if (ctx.last_pos < range.start_byte) {
                ctx.writer.writeAll(ctx.content[ctx.last_pos..range.start_byte]) catch return error.Stop;
                ctx.last_pos = range.start_byte;
            }
            if (range.start_byte < ctx.last_pos) return;

            const plain: Theme.Style = Theme.Style{ .fg = ctx.theme.editor.fg };
            if (style_cache_lookup(ctx.theme, scope, id)) |token| {
                set_ansi_style(ctx.writer, token.style, plain) catch return error.Stop;
                ctx.writer.writeAll(ctx.content[range.start_byte..range.end_byte]) catch return error.Stop;
                set_ansi_style(ctx.writer, plain, plain) catch return error.Stop;
            } else {
                ctx.writer.writeAll(ctx.content[range.start_byte..range.end_byte]) catch return error.Stop;
            }
            ctx.last_pos = range.end_byte;
        }
    };
    var ctx: Ctx = .{ .writer = writer, .content = content, .theme = theme };
    try parser.render(&ctx, Ctx.cb);
    try ctx.writer.writeAll(content[ctx.last_pos..]);
}

fn style_cache_lookup(theme: *const Theme, scope: []const u8, id: u32) ?Theme.Token {
    return if (style_cache.get(id)) |sty| ret: {
        break :ret sty;
    } else ret: {
        const sty = find_scope_style(theme, scope) orelse null;
        style_cache.put(id, sty) catch {};
        break :ret sty;
    };
}

fn find_scope_style(theme: *const Theme, scope: []const u8) ?Theme.Token {
    return if (find_scope_fallback(scope)) |tm_scope|
        find_scope_style_nofallback(theme, tm_scope) orelse find_scope_style_nofallback(theme, scope)
    else
        find_scope_style_nofallback(theme, scope);
}

fn find_scope_style_nofallback(theme: *const Theme, scope: []const u8) ?Theme.Token {
    var idx = theme.tokens.len - 1;
    var done = false;
    while (!done) : (if (idx == 0) {
        done = true;
    } else {
        idx -= 1;
    }) {
        const token = theme.tokens[idx];
        const name = themes.scopes[token.id];
        if (name.len > scope.len)
            continue;
        if (std.mem.eql(u8, name, scope[0..name.len]))
            return token;
    }
    return null;
}

fn find_scope_fallback(scope: []const u8) ?[]const u8 {
    for (fallbacks) |fallback| {
        if (fallback.ts.len > scope.len)
            continue;
        if (std.mem.eql(u8, fallback.ts, scope[0..fallback.ts.len]))
            return fallback.tm;
    }
    return null;
}

pub const FallBack = struct { ts: []const u8, tm: []const u8 };
pub const fallbacks: []const FallBack = &[_]FallBack{
    .{ .ts = "namespace", .tm = "entity.name.namespace" },
    .{ .ts = "type", .tm = "entity.name.type" },
    .{ .ts = "type.defaultLibrary", .tm = "support.type" },
    .{ .ts = "struct", .tm = "storage.type.struct" },
    .{ .ts = "class", .tm = "entity.name.type.class" },
    .{ .ts = "class.defaultLibrary", .tm = "support.class" },
    .{ .ts = "interface", .tm = "entity.name.type.interface" },
    .{ .ts = "enum", .tm = "entity.name.type.enum" },
    .{ .ts = "function", .tm = "entity.name.function" },
    .{ .ts = "function.defaultLibrary", .tm = "support.function" },
    .{ .ts = "method", .tm = "entity.name.function.member" },
    .{ .ts = "macro", .tm = "entity.name.function.macro" },
    .{ .ts = "variable", .tm = "variable.other.readwrite , entity.name.variable" },
    .{ .ts = "variable.readonly", .tm = "variable.other.constant" },
    .{ .ts = "variable.readonly.defaultLibrary", .tm = "support.constant" },
    .{ .ts = "parameter", .tm = "variable.parameter" },
    .{ .ts = "property", .tm = "variable.other.property" },
    .{ .ts = "property.readonly", .tm = "variable.other.constant.property" },
    .{ .ts = "enumMember", .tm = "variable.other.enummember" },
    .{ .ts = "event", .tm = "variable.other.event" },

    // zig
    .{ .ts = "attribute", .tm = "keyword" },
    .{ .ts = "number", .tm = "constant.numeric" },
    .{ .ts = "conditional", .tm = "keyword.control.conditional" },
    .{ .ts = "operator", .tm = "keyword.operator" },
    .{ .ts = "boolean", .tm = "keyword.constant.bool" },
    .{ .ts = "string", .tm = "string.quoted" },
    .{ .ts = "repeat", .tm = "keyword.control.flow" },
    .{ .ts = "field", .tm = "variable" },
};

fn get_theme_by_name(name: []const u8) ?Theme {
    for (themes.themes) |theme| {
        if (std.mem.eql(u8, theme.name, name))
            return theme;
    }
    return null;
}

fn list_themes(writer: anytype) !void {
    var max_name_len: usize = 0;
    for (themes.themes) |theme|
        max_name_len = @max(max_name_len, theme.name.len);

    for (themes.themes) |theme| {
        try writer.writeAll(theme.name);
        try writer.writeByteNTimes(' ', max_name_len + 2 - theme.name.len);
        try writer.writeAll(theme.description);
        try writer.writeAll("\n");
    }
}

fn set_ansi_style(writer: anytype, style: Theme.Style, fallback: Theme.Style) !void {
    const ansi_style = .{
        .foreground = if (style.fg) |color| to_rgb_color(color) else if (fallback.fg) |color| to_rgb_color(color) else .Default,
        .background = if (style.bg) |color| to_rgb_color(color) else if (fallback.bg) |color| to_rgb_color(color) else .Default,
        .font_style = switch (style.fs orelse .normal) {
            .normal => term.style.FontStyle{},
            .bold => term.style.FontStyle.bold,
            .italic => term.style.FontStyle.italic,
            .underline => term.style.FontStyle.underline,
            .strikethrough => term.style.FontStyle.crossedout,
        },
    };
    try term.format.updateStyle(writer, ansi_style, null);
}

fn to_rgb_color(color: u24) term.style.Color {
    const r = @as(u8, @intCast(color >> 16 & 0xFF));
    const g = @as(u8, @intCast(color >> 8 & 0xFF));
    const b = @as(u8, @intCast(color & 0xFF));
    return .{ .RGB = .{ .r = r, .g = g, .b = b } };
}

fn list_langs(writer: anytype) !void {
    for (syntax.FileType.file_types) |file_type| {
        try writer.writeAll(file_type.name);
        try writer.writeAll("\n");
    }
}

fn render_file_type(writer: anytype, file_type: *const syntax.FileType, theme: *const Theme) !void {
    const style = theme.editor_selection;
    const reversed = Theme.Style{ .fg = theme.editor_selection.bg };
    const plain: Theme.Style = Theme.Style{ .fg = theme.editor.fg };
    try set_ansi_style(writer, reversed, plain);
    try writer.writeAll("");
    try set_ansi_style(writer, .{
        .fg = if (file_type.color == 0xFFFFFF or file_type.color == 0x000000) style.fg else file_type.color,
        .bg = style.bg,
    }, plain);
    try writer.writeAll(file_type.icon);
    try writer.writeAll(" ");
    try set_ansi_style(writer, style, plain);
    try writer.writeAll(file_type.name);
    try set_ansi_style(writer, reversed, plain);
    try writer.writeAll("");
    try set_ansi_style(writer, plain, plain);
    try writer.writeAll("\n");
}
