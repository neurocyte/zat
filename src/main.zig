const std = @import("std");
const clap = @import("clap");
const syntax = @import("syntax");
const Theme = @import("theme");
const themes = @import("themes");
const term = @import("ansi-term.zig");
const config_loader = @import("config_loader.zig");

const Writer = std.io.BufferedWriter(4096, std.fs.File.Writer).Writer;
const StyleCache = std.AutoHashMap(u32, ?Theme.Token);
var style_cache: StyleCache = undefined;
var lang_override: ?[]const u8 = null;
var lang_default: []const u8 = "conf";
const no_highlight = std.math.maxInt(usize);

pub fn main() !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-l, --language <name>    Override the language.
        \\-t, --theme <name>       Select theme to use.
        \\-d, --default <name>     Set the language to use if guessing failed (default: conf).
        \\-s, --show-language      Show detected language in output.
        \\--html                   Output HTML instead of ansi escape codes.
        \\--list-themes            Show available themes.
        \\--list-languages         Show available language parsers.
        \\-H, --highlight <range>  Highlight a line or a line range:
        \\                         * LINE highlight just a single whole line
        \\                         * LINE,LINE highlight a line range
        \\-L, --limit <lines>      Limit output to <lines> around <range> or from the beginning.
        \\<file>...                File to open.
        \\
    );

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    const a = gpa.allocator();
    style_cache = StyleCache.init(a);

    const parsers = comptime .{
        .name = clap.parsers.string,
        .file = clap.parsers.string,
        .range = clap.parsers.string,
        .lines = clap.parsers.int(usize, 10),
    };
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = a,
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch {};
        clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{}) catch {};
        std.process.exit(1);
        return err;
    };
    defer res.deinit();

    const stdout_file = std.io.getStdOut().writer();
    var bw = std.io.bufferedWriter(stdout_file);
    const writer = bw.writer();
    defer bw.flush() catch {};

    if (res.args.help != 0)
        return clap.help(std.io.getStdErr().writer(), clap.Help, &params, .{});

    if (res.args.@"list-themes" != 0)
        return list_themes(writer);

    if (res.args.@"list-languages" != 0)
        return list_langs(writer);

    var conf_buf: ?[]const u8 = null;
    const conf = config_loader.read_config(a, &conf_buf);
    const theme_name = if (res.args.theme) |theme| theme else conf.theme;
    const limit_lines = res.args.limit;

    var highlight_line_start: usize = no_highlight;
    var highlight_line_end: usize = no_highlight;
    if (res.args.highlight) |parm| {
        var it = std.mem.splitScalar(u8, parm, ',');
        highlight_line_start = std.fmt.parseInt(usize, it.first(), 10) catch no_highlight;
        highlight_line_end = highlight_line_start;
        if (it.next()) |end|
            highlight_line_end = std.fmt.parseInt(usize, end, 10) catch highlight_line_start;
    }

    if (highlight_line_end < highlight_line_start) {
        try std.io.getStdErr().writer().print("invalid range\n", .{});
        std.process.exit(1);
    }

    const theme = get_theme_by_name(theme_name) orelse {
        try std.io.getStdErr().writer().print("theme \"{s}\" not found\n", .{theme_name});
        std.process.exit(1);
    };

    const set_style: StyleFn = if (res.args.html != 0) set_html_style else set_ansi_style;
    const unset_style: StyleFn = if (res.args.html != 0) unset_html_style else unset_ansi_style;

    lang_override = res.args.language;
    if (res.args.default) |default| lang_default = default;

    if (res.args.html != 0)
        try write_html_preamble(writer, theme.editor);

    if (res.positionals.len > 0) {
        for (res.positionals) |arg| {
            const file = try std.fs.cwd().openFile(arg, .{ .mode = .read_only });
            defer file.close();
            const content = try file.readToEndAlloc(a, std.math.maxInt(u32));
            defer a.free(content);
            render_file(
                a,
                writer,
                content,
                arg,
                &theme,
                res.args.@"show-language" != 0,
                set_style,
                unset_style,
                highlight_line_start,
                highlight_line_end,
                limit_lines,
            ) catch |e| switch (e) {
                error.Stop => return,
                else => return e,
            };
            try bw.flush();
        }
    } else {
        const content = try std.io.getStdIn().readToEndAlloc(a, std.math.maxInt(u32));
        defer a.free(content);
        render_file(
            a,
            writer,
            content,
            "-",
            &theme,
            res.args.@"show-language" != 0,
            set_style,
            unset_style,
            highlight_line_start,
            highlight_line_end,
            limit_lines,
        ) catch |e| switch (e) {
            error.Stop => return,
            else => return e,
        };
    }

    if (res.args.html != 0)
        try write_html_postamble(writer);
}

fn get_parser(a: std.mem.Allocator, content: []const u8, file_path: []const u8) *syntax {
    return (if (lang_override) |name|
        syntax.create_file_type(a, content, name) catch unknown_file_type(name)
    else
        syntax.create_guess_file_type(a, content, file_path)) catch syntax.create_file_type(a, content, lang_default) catch unknown_file_type(lang_default);
}

fn unknown_file_type(name: []const u8) noreturn {
    std.io.getStdErr().writer().print("unknown file type \'{s}\'\n", .{name}) catch {};
    std.process.exit(1);
}

const StyleFn = *const fn (writer: Writer, style: Theme.Style) Writer.Error!void;

fn render_file(
    a: std.mem.Allocator,
    writer: Writer,
    content: []const u8,
    file_path: []const u8,
    theme: *const Theme,
    show: bool,
    set_style: StyleFn,
    unset_style: StyleFn,
    highlight_line_start: usize,
    highlight_line_end: usize,
    limit_lines: ?usize,
) !void {
    var start_line: usize = 1;
    var end_line: usize = std.math.maxInt(usize);

    if (limit_lines) |lines| {
        const center = (lines - 1) / 2;
        if (highlight_line_start != no_highlight) {
            const range_size = highlight_line_end - highlight_line_start;
            const top = center - @min(center, range_size / 2);
            if (highlight_line_start > top) {
                start_line = highlight_line_start - top;
            }
        }
        end_line = start_line + lines;
    }

    const parser = get_parser(a, content, file_path);
    if (show) {
        try render_file_type(writer, parser.file_type, theme);
        end_line -= 1;
    }

    const Ctx = struct {
        writer: @TypeOf(writer),
        content: []const u8,
        theme: *const Theme,
        last_pos: usize = 0,
        set_style: StyleFn,
        unset_style: StyleFn,
        start_line: usize,
        end_line: usize,
        highlight_line_start: usize,
        highlight_line_end: usize,
        current_line: usize = 1,

        fn write_styled(ctx: *@This(), text: []const u8, style: Theme.Style) !void {
            if (!(ctx.start_line <= ctx.current_line and ctx.current_line <= ctx.end_line)) return;

            const style_: Theme.Style = if (ctx.highlight_line_start <= ctx.current_line and ctx.current_line <= ctx.highlight_line_end)
                .{ .fg = style.fg, .bg = ctx.theme.editor_line_highlight.bg }
            else
                .{ .fg = style.fg };

            try ctx.set_style(ctx.writer, style_);
            try ctx.writer.writeAll(text);
            try ctx.unset_style(ctx.writer, .{ .fg = ctx.theme.editor.fg });
        }

        fn write_lines_styled(ctx: *@This(), text_: []const u8, style: Theme.Style) !void {
            var text = text_;
            while (std.mem.indexOf(u8, text, "\n")) |pos| {
                try ctx.write_styled(text[0 .. pos + 1], style);
                ctx.current_line += 1;
                text = text[pos + 1 ..];
            }
            try ctx.write_styled(text, style);
        }

        fn cb(ctx: *@This(), range: syntax.Range, scope: []const u8, id: u32, idx: usize, _: *const syntax.Node) error{Stop}!void {
            if (idx > 0) return;

            if (ctx.last_pos < range.start_byte) {
                const before_segment = ctx.content[ctx.last_pos..range.start_byte];
                ctx.write_lines_styled(before_segment, ctx.theme.editor) catch return error.Stop;
                ctx.last_pos = range.start_byte;
            }

            if (range.start_byte < ctx.last_pos) return;

            const scope_segment = ctx.content[range.start_byte..range.end_byte];
            if (style_cache_lookup(ctx.theme, scope, id)) |token| {
                ctx.write_lines_styled(scope_segment, token.style) catch return error.Stop;
            } else {
                ctx.write_lines_styled(scope_segment, ctx.theme.editor) catch return error.Stop;
            }
            ctx.last_pos = range.end_byte;
            if (ctx.current_line >= ctx.end_line)
                return error.Stop;
        }
    };
    var ctx: Ctx = .{
        .writer = writer,
        .content = content,
        .theme = theme,
        .set_style = set_style,
        .unset_style = unset_style,
        .start_line = start_line,
        .end_line = end_line,
        .highlight_line_start = highlight_line_start,
        .highlight_line_end = highlight_line_end,
    };
    const range: ?syntax.Range = ret: {
        if (limit_lines) |_| break :ret .{
            .start_point = .{ .row = @intCast(start_line - 1), .column = 0 },
            .end_point = .{ .row = @intCast(end_line - 1), .column = 0 },
            .start_byte = 0,
            .end_byte = 0,
        };
        break :ret null;
    };
    try parser.render(&ctx, Ctx.cb, range);
    while (ctx.current_line < end_line) {
        if (std.mem.indexOfPos(u8, content, ctx.last_pos, "\n")) |pos| {
            try ctx.writer.writeAll(content[ctx.last_pos .. pos + 1]);
            ctx.current_line += 1;
            ctx.last_pos = pos + 1;
        } else {
            try ctx.writer.writeAll(content[ctx.last_pos..]);
            break;
        }
    }
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

fn list_themes(writer: Writer) !void {
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

fn set_ansi_style(writer: Writer, style: Theme.Style) Writer.Error!void {
    const ansi_style = .{
        .foreground = if (style.fg) |color| to_rgb_color(color) else .Default,
        .background = if (style.bg) |color| to_rgb_color(color) else .Default,
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

const unset_ansi_style = set_ansi_style;

fn write_html_preamble(writer: Writer, style: Theme.Style) !void {
    const color = if (style.fg) |color| color else 0;
    const background = if (style.bg) |background| background else 0xFFFFFF;
    try writer.writeAll("<div style=\"color:");
    try write_hex_color(writer, color);
    try writer.writeAll(";background-color:");
    try write_hex_color(writer, background);
    try writer.writeAll(";\"><pre>");
}

fn write_html_postamble(writer: Writer) !void {
    try writer.writeAll("</pre></div>");
}

fn set_html_style(writer: Writer, style: Theme.Style) !void {
    const color = if (style.fg) |color| color else 0;
    try writer.writeAll("<span style=\"color:");
    try write_hex_color(writer, color);
    switch (style.fs orelse .normal) {
        .normal => {},
        .bold => try writer.writeAll(";font-weight: bold"),
        .italic => try writer.writeAll(";font-style: italic"),
        .underline => try writer.writeAll(";text-decoration: underline"),
        .strikethrough => try writer.writeAll(";text-decoration: line-through"),
    }
    try writer.writeAll(";\">");
}

fn unset_html_style(writer: Writer, _: Theme.Style) !void {
    try writer.writeAll("</span>");
}

fn to_rgb_color(color: u24) term.style.Color {
    const r = @as(u8, @intCast(color >> 16 & 0xFF));
    const g = @as(u8, @intCast(color >> 8 & 0xFF));
    const b = @as(u8, @intCast(color & 0xFF));
    return .{ .RGB = .{ .r = r, .g = g, .b = b } };
}

fn write_hex_color(writer: Writer, color: u24) !void {
    try writer.print("#{x:0>6}", .{color});
}

fn list_langs(writer: Writer) !void {
    for (syntax.FileType.file_types) |file_type| {
        try writer.writeAll(file_type.name);
        try writer.writeAll("\n");
    }
}

fn render_file_type(writer: Writer, file_type: *const syntax.FileType, theme: *const Theme) !void {
    const style = theme.editor_selection;
    const reversed = Theme.Style{ .fg = theme.editor_selection.bg };
    const plain: Theme.Style = Theme.Style{ .fg = theme.editor.fg };
    try set_ansi_style(writer, reversed);
    try writer.writeAll("");
    try set_ansi_style(writer, .{
        .fg = if (file_type.color == 0xFFFFFF or file_type.color == 0x000000) style.fg else file_type.color,
        .bg = style.bg,
    });
    try writer.writeAll(file_type.icon);
    try writer.writeAll(" ");
    try set_ansi_style(writer, style);
    try writer.writeAll(file_type.name);
    try set_ansi_style(writer, reversed);
    try writer.writeAll("");
    try set_ansi_style(writer, plain);
    try writer.writeAll("\n");
}
