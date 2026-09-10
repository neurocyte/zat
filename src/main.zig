const std = @import("std");
const clap = @import("clap");
const syntax = @import("syntax");
const cbor = @import("cbor");
const Theme = @import("theme");
const themes = @import("themes");
const term = @import("ansi_term");
const config_loader = @import("config_loader.zig");

const Writer = std.Io.Writer;
const StyleCache = std.AutoHashMap(u32, ?Theme.Token);
var style_cache: StyleCache = undefined;
var lang_override: ?[]const u8 = null;
var lang_default: []const u8 = "conf";
const no_highlight = std.math.maxInt(usize);

const builtin = @import("builtin");
pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .info else .err,
};

pub fn main(init: std.process.Init) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help               Display this help and exit.
        \\-l, --language <name>    Override the language.
        \\-t, --theme <name>       Select theme to use.
        \\-d, --default <name>     Set the language to use if guessing failed (default: conf).
        \\-s, --show-language      Show detected language in output.
        \\-T, --show-theme         Show selected theme in output.
        \\-C, --color              Always produce color output, even if stdout is not a tty.
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

    const a = init.gpa;
    style_cache = StyleCache.init(a);
    defer style_cache.deinit();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_file = std.Io.File.writer(std.Io.File.stderr(), init.io, &stderr_buf);
    const stderr = &stderr_file.interface;
    defer stderr_file.flush() catch {};

    const parsers = comptime .{
        .name = clap.parsers.string,
        .file = clap.parsers.string,
        .range = clap.parsers.string,
        .lines = clap.parsers.int(usize, 10),
    };
    var diag = clap.Diagnostic{};
    var res = clap.parse(clap.Help, &params, parsers, init.minimal.args, .{
        .diagnostic = &diag,
        .allocator = a,
    }) catch |err| {
        diag.report(stderr, err) catch {};
        clap.help(stderr, clap.Help, &params, .{}) catch {};
        std.process.exit(1);
        return err;
    };
    defer res.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_file = std.Io.File.writer(std.Io.File.stdout(), init.io, &stdout_buf);
    const stdout = &stdout_file.interface;
    defer stdout_file.flush() catch {};

    if (res.args.help != 0)
        return clap.help(stderr, clap.Help, &params, .{});

    if (res.args.@"list-themes" != 0)
        return list_themes(stdout);

    if (res.args.@"list-languages" != 0)
        return list_langs(stdout);

    if (res.args.color == 0) {
        const tty_mode = std.Io.Terminal.Mode.detect(init.io, std.Io.File.stdout(), false, false) catch .no_color;
        if (tty_mode == .no_color)
            return plain_cat(init.io, stdout, res.positionals.@"0");
    }

    const conf, const conf_bufs = config_loader.read_config(init.io, init.environ_map, @import("config.zig"), a);
    defer config_loader.free_config(a, conf_bufs);
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
        std.log.err("invalid range", .{});
        std.process.exit(1);
    }

    const theme, const parsed_theme = config_loader.get_theme_by_name(init.io, init.environ_map, a, theme_name) orelse {
        std.log.err("theme \"{s}\" not found", .{theme_name});
        std.process.exit(1);
    };
    _ = parsed_theme;

    const set_style: StyleFn = if (res.args.html != 0) set_html_style else set_ansi_style;
    const unset_style: StyleFn = if (res.args.html != 0) unset_html_style else unset_ansi_style;

    lang_override = res.args.language;
    if (res.args.default) |default| lang_default = default;

    if (res.args.html != 0)
        try write_html_preamble(stdout, theme.editor);

    if (res.positionals.@"0".len > 0) {
        for (res.positionals.@"0") |arg| {
            const file = if (std.mem.eql(u8, arg, "-"))
                std.Io.File.stdin()
            else
                try std.Io.Dir.cwd().openFile(init.io, arg, .{ .mode = .read_only });
            defer file.close(init.io);
            var file_read_buf: [4096]u8 = undefined;
            var file_rdr = std.Io.File.reader(file, init.io, &file_read_buf);
            const content = try file_rdr.interface.allocRemaining(a, .limited(std.math.maxInt(u32)));
            defer a.free(content);
            render_file(
                init.io,
                a,
                stdout,
                content,
                arg,
                &theme,
                res.args.@"show-language" != 0,
                res.args.@"show-theme" != 0,
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
    } else {
        var stdin_read_buf: [4096]u8 = undefined;
        var stdin_rdr = std.Io.File.reader(std.Io.File.stdin(), init.io, &stdin_read_buf);
        const content = try stdin_rdr.interface.allocRemaining(a, .limited(std.math.maxInt(u32)));
        defer a.free(content);
        render_file(
            init.io,
            a,
            stdout,
            content,
            "-",
            &theme,
            res.args.@"show-language" != 0,
            res.args.@"show-theme" != 0,
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

    try stdout_file.flush();

    if (res.args.html != 0)
        try write_html_postamble(stdout);
}

fn get_parser(a: std.mem.Allocator, content: []const u8, file_path: []const u8, query_cache: *syntax.QueryCache) struct { syntax.FileType, *syntax } {
    return if (lang_override) |name| blk: {
        const file_type = syntax.FileType.get_by_name_static(name) orelse unknown_file_type(name);
        break :blk .{ file_type, syntax.create(file_type, a, query_cache) catch unknown_file_type(name) };
    } else blk: {
        const file_type = syntax.FileType.guess_static(file_path, content) orelse
            syntax.FileType.get_by_name_static(lang_default) orelse
            unknown_file_type(lang_default);
        break :blk .{ file_type, syntax.create(file_type, a, query_cache) catch unknown_file_type(lang_default) };
    };
}

fn unknown_file_type(name: []const u8) noreturn {
    std.log.err("unknown file type \'{s}\'\n", .{name});
    std.process.exit(1);
}

const StyleFn = *const fn (writer: *Writer, style: Theme.Style) Writer.Error!void;

const Highlight = struct {
    start_byte: usize,
    end_byte: usize,
    token: Theme.Token,
    rank: i64,
};

fn render_file(
    io: std.Io,
    a: std.mem.Allocator,
    writer: *Writer,
    content: []const u8,
    file_path: []const u8,
    theme: *const Theme,
    show_file_type: bool,
    show_theme: bool,
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

    const query_cache = try syntax.QueryCache.create(io, a, .{});
    defer query_cache.deinit();
    const file_type, const parser = get_parser(a, content, file_path, query_cache);
    defer parser.destroy();
    try parser.refresh_full(content);
    if (show_file_type) {
        try render_file_type(writer, &file_type, theme);
        end_line -= 1;
    }
    if (show_theme) {
        try render_theme_indicator(writer, theme);
        end_line -= 1;
    }

    const Ctx = struct {
        content: []const u8,
        theme: *const Theme,
        allocator: std.mem.Allocator,
        highlights: std.ArrayList(Highlight),
        start_line: usize,
        end_line: usize,

        fn cb(ctx: *@This(), range: syntax.Range, scope: []const u8, id: u32, idx: usize, priority: i32, pattern_index: u32, _: *const syntax.Node) error{Stop}!void {
            if (idx > 0) return;
            if (range.start_point.row + 1 < ctx.start_line or range.start_point.row >= ctx.end_line) return;

            const token = style_cache_lookup(ctx.theme, scope, id) orelse return;
            const rank: i64 = (@as(i64, priority) << 32) | @as(i64, pattern_index);
            ctx.highlights.append(ctx.allocator, .{
                .start_byte = range.start_byte,
                .end_byte = range.end_byte,
                .token = token,
                .rank = rank,
            }) catch return error.Stop;
        }
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

    var hl_ctx = Ctx{
        .content = content,
        .theme = theme,
        .allocator = a,
        .highlights = std.ArrayList(Highlight).initCapacity(a, 64) catch return error.OutOfMemory,
        .start_line = start_line,
        .end_line = end_line,
    };
    defer hl_ctx.highlights.deinit(a);

    try parser.render(&hl_ctx, Ctx.cb, syntax.SimpleNonRegex(*Ctx), range);
    const hl_list = hl_ctx.highlights;

    var line_start: usize = 0;
    var line_num: usize = 1;

    while (line_start < content.len and line_num <= end_line) {
        const line_len = std.mem.indexOfScalar(u8, content[line_start..], '\n') orelse content.len - line_start;
        const line_end = line_start + line_len;

        if (line_num >= start_line) {
            const line_selected = line_num >= highlight_line_start and line_num <= highlight_line_end;

            var line_hl = std.ArrayList(Highlight).initCapacity(a, 16) catch return error.OutOfMemory;
            defer line_hl.deinit(a);

            // A highlight only needs to *overlap* the line, not start on
            // it to handle multi-line tokens correctly
            for (hl_list.items) |hl| {
                if (hl.start_byte < line_end and hl.end_byte > line_start) {
                    try line_hl.append(a, hl);
                }
            }

            std.sort.heap(Highlight, line_hl.items, {}, struct {
                fn lessThan(_: void, lhs: Highlight, rhs: Highlight) bool {
                    return lhs.rank > rhs.rank;
                }
            }.lessThan);

            const coverage = a.alloc(usize, line_len) catch {
                line_start = line_end + 1;
                line_num += 1;
                continue;
            };
            defer a.free(coverage);
            @memset(coverage, std.math.maxInt(usize));

            for (line_hl.items, 0..) |hl, hl_idx| {
                const hl_start = @max(hl.start_byte, line_start) - line_start;
                const hl_end = @min(hl.end_byte, line_end) - line_start;
                var i: usize = hl_start;
                while (i < hl_end) : (i += 1) {
                    if (coverage[i] == std.math.maxInt(usize)) {
                        coverage[i] = hl_idx;
                    }
                }
            }

            var i: usize = 0;
            while (i < line_len) {
                const cov_idx = coverage[i];
                const seg_start = i;

                while (i < line_len and coverage[i] == cov_idx) {
                    i += 1;
                }
                const abs_start = seg_start + line_start;
                const abs_end = i + line_start;

                const style = if (cov_idx == std.math.maxInt(usize))
                    theme.editor
                else
                    line_hl.items[cov_idx].token.style;

                const style_ = if (line_selected)
                    Theme.Style{ .fg = style.fg, .bg = theme.editor_selection.bg }
                else
                    Theme.Style{ .fg = style.fg };

                try set_style(writer, style_);
                try writer.writeAll(content[abs_start..abs_end]);
                try unset_style(writer, .{ .fg = theme.editor.fg });
            }

            if (line_end < content.len) {
                try writer.writeAll("\n");
            }
        }

        line_start = line_end + 1;
        line_num += 1;
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

fn list_themes(writer: *Writer) !void {
    var max_name_len: usize = 0;
    for (themes.themes) |theme|
        max_name_len = @max(max_name_len, theme.name.len);

    for (themes.themes) |theme| {
        try writer.writeAll(theme.name);
        for (0..max_name_len + 2 - theme.name.len) |_|
            try writer.writeByte(' ');
        try writer.writeAll(theme.description);
        try writer.writeAll("\n");
    }
}

fn set_ansi_style(writer: *Writer, style: Theme.Style) Writer.Error!void {
    const ansi_style: term.style.Style = .{
        .foreground = if (style.fg) |color| to_rgb_color(color.color) else .Default,
        .background = if (style.bg) |color| to_rgb_color(color.color) else .Default,
        .font_style = switch (style.fs orelse .normal) {
            .normal => term.style.FontStyle{},
            .bold => term.style.FontStyle{ .bold = true },
            .italic => term.style.FontStyle{ .italic = true },
            .underline => term.style.FontStyle{ .underline = true },
            .undercurl => term.style.FontStyle{ .underline = true },
            .strikethrough => term.style.FontStyle{ .crossedout = true },
        },
    };
    try term.format.updateStyle(writer, ansi_style, null);
}

const unset_ansi_style = set_ansi_style;

fn write_html_preamble(writer: *Writer, style: Theme.Style) !void {
    const color = if (style.fg) |color| color.color else 0;
    const background = if (style.bg) |background| background.color else 0xFFFFFF;
    try writer.writeAll("<div style=\"color:");
    try write_hex_color(writer, color);
    try writer.writeAll(";background-color:");
    try write_hex_color(writer, background);
    try writer.writeAll(";\"><pre>");
}

fn write_html_postamble(writer: *Writer) !void {
    try writer.writeAll("</pre></div>");
}

fn set_html_style(writer: *Writer, style: Theme.Style) !void {
    const color = if (style.fg) |color| color.color else 0;
    try writer.writeAll("<span style=\"color:");
    try write_hex_color(writer, color);
    switch (style.fs orelse .normal) {
        .normal => {},
        .bold => try writer.writeAll(";font-weight: bold"),
        .italic => try writer.writeAll(";font-style: italic"),
        .underline => try writer.writeAll(";text-decoration: underline"),
        .undercurl => try writer.writeAll(";text-decoration: underline wavy"),
        .strikethrough => try writer.writeAll(";text-decoration: line-through"),
    }
    try writer.writeAll(";\">");
}

fn unset_html_style(writer: *Writer, _: Theme.Style) !void {
    try writer.writeAll("</span>");
}

fn to_rgb_color(color: u24) term.style.Color {
    const r = @as(u8, @intCast(color >> 16 & 0xFF));
    const g = @as(u8, @intCast(color >> 8 & 0xFF));
    const b = @as(u8, @intCast(color & 0xFF));
    return .{ .RGB = .{ .r = r, .g = g, .b = b } };
}

fn write_hex_color(writer: *Writer, color: u24) !void {
    try writer.print("#{x:0>6}", .{color});
}

fn list_langs(writer: *Writer) !void {
    const all = syntax.FileType.get_all();
    const sorted = try std.heap.page_allocator.alloc(syntax.FileType, all.len);
    defer std.heap.page_allocator.free(sorted);
    @memcpy(sorted, all);
    std.mem.sort(
        syntax.FileType,
        sorted,
        {},
        struct {
            fn cmp(_: void, a: syntax.FileType, b: syntax.FileType) bool {
                return std.mem.lessThan(u8, a.name, b.name);
            }
        }.cmp,
    );
    for (sorted) |file_type| {
        try writer.writeAll(file_type.name);
        try writer.writeAll("\n");
    }
}

fn render_file_type(writer: *Writer, file_type: *const syntax.FileType, theme: *const Theme) !void {
    const style = theme.editor_selection;
    const reversed = Theme.Style{ .fg = theme.editor_selection.bg };
    const plain: Theme.Style = Theme.Style{ .fg = theme.editor.fg };
    try set_ansi_style(writer, reversed);
    try writer.writeAll("");
    try set_ansi_style(writer, .{
        .fg = if (file_type.color == 0xFFFFFF or file_type.color == 0x000000) style.fg else .{ .color = file_type.color },
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

fn render_theme_indicator(writer: *Writer, theme: *const Theme) !void {
    const style = Theme.Style{ .bg = theme.editor_selection.bg, .fg = theme.editor.fg };
    const reversed = Theme.Style{ .fg = theme.editor_selection.bg };
    const plain: Theme.Style = Theme.Style{ .fg = theme.editor.fg };
    try set_ansi_style(writer, reversed);
    try writer.writeAll("");
    try set_ansi_style(writer, style);
    try writer.writeAll(theme.name);
    try set_ansi_style(writer, reversed);
    try writer.writeAll("");
    try set_ansi_style(writer, plain);
    try writer.writeAll("\n");
}

fn plain_cat(io: std.Io, stdout: *Writer, files: []const []const u8) !void {
    if (files.len == 0) {
        try plain_cat_file(io, stdout, "-");
    } else {
        for (files) |file| try plain_cat_file(io, stdout, file);
    }
}

fn plain_cat_file(io: std.Io, stdout: *Writer, in_file_name: []const u8) !void {
    var in_file = if (std.mem.eql(u8, in_file_name, "-"))
        std.Io.File.stdin()
    else
        try std.Io.Dir.cwd().openFile(io, in_file_name, .{});
    defer in_file.close(io);

    var buf: [std.heap.page_size_min]u8 = undefined;
    var rdr = std.Io.File.reader(in_file, io, &buf);
    _ = try rdr.interface.streamRemaining(stdout);
}
