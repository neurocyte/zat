const std = @import("std");
const cbor = @import("cbor");
const Theme = @import("theme");
const themes = @import("themes");
const builtin = @import("builtin");

const application_name = "flow";

pub fn read_config(io: std.Io, env: *const std.process.Environ.Map, T: type, allocator: std.mem.Allocator) struct { T, [][]const u8 } {
    var bufs: [][]const u8 = &[_][]const u8{};
    const json_file_name = get_app_config_file_name(io, env, application_name, @typeName(T)) catch return .{ .{}, bufs };
    const text_file_name = json_file_name[0 .. json_file_name.len - ".json".len];
    var conf: T = .{};
    if (!read_config_file(io, T, allocator, &conf, &bufs, text_file_name)) {
        _ = read_config_file(io, T, allocator, &conf, &bufs, json_file_name);
    }
    read_nested_include_files(io, T, allocator, &conf, &bufs);
    return .{ conf, bufs };
}

pub fn free_config(allocator: std.mem.Allocator, bufs: [][]const u8) void {
    for (bufs) |buf| allocator.free(buf);
}

// returns true if the file was found
fn read_config_file(io: std.Io, T: type, allocator: std.mem.Allocator, conf: *T, bufs: *[][]const u8, file_name: []const u8) bool {
    std.log.info("loading {s}", .{file_name});
    const err: anyerror = blk: {
        if (std.mem.endsWith(u8, file_name, ".json")) if (read_json_config_file(io, T, allocator, conf, bufs, file_name)) return true else |e| break :blk e;
        if (read_text_config_file(io, T, allocator, conf, bufs, file_name)) return true else |e| break :blk e;
    };
    switch (err) {
        error.FileNotFound => return false,
        else => |e| std.log.err("error reading config file '{s}': {s}", .{ file_name, @errorName(e) }),
    }
    return true;
}

fn read_text_config_file(io: std.Io, T: type, allocator: std.mem.Allocator, conf: *T, bufs_: *[][]const u8, file_name: []const u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, file_name, .{ .mode = .read_only });
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var rdr = std.Io.File.reader(file, io, &read_buf);
    const content = try rdr.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(content);
    return parse_text_config_file(T, allocator, conf, bufs_, file_name, content);
}

pub fn parse_text_config_file(T: type, allocator: std.mem.Allocator, conf: *T, bufs_: *[][]const u8, file_name: []const u8, content: []const u8) !void {
    var cbor_buf: std.Io.Writer.Allocating = .init(allocator);
    defer cbor_buf.deinit();
    const writer = &cbor_buf.writer;
    var it = std.mem.splitScalar(u8, content, '\n');
    var lineno: u32 = 0;
    while (it.next()) |line| {
        lineno += 1;
        if (line.len == 0 or line[0] == '#')
            continue;
        const spc = std.mem.indexOfScalar(u8, line, ' ') orelse {
            std.log.err("{s}:{}: {s} missing value", .{ file_name, lineno, line });
            continue;
        };
        const name = line[0..spc];
        const value_str = line[spc + 1 ..];
        const cb = cbor.fromJsonAlloc(allocator, value_str) catch {
            std.log.err("{s}:{}: {s} has bad value: {s}", .{ file_name, lineno, name, value_str });
            continue;
        };
        defer allocator.free(cb);
        try cbor.writeValue(writer, name);
        try writer.writeAll(cb);
    }
    const cb = try cbor_buf.toOwnedSlice();
    var bufs = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(bufs_.*);
    bufs.append(allocator, cb) catch @panic("OOM:read_text_config_file");
    bufs_.* = bufs.toOwnedSlice(allocator) catch @panic("OOM:read_text_config_file");
    return read_cbor_config(T, conf, file_name, cb);
}

fn read_json_config_file(io: std.Io, T: type, allocator: std.mem.Allocator, conf: *T, bufs_: *[][]const u8, file_name: []const u8) !void {
    var file = try std.Io.Dir.openFileAbsolute(io, file_name, .{ .mode = .read_only });
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var rdr = std.Io.File.reader(file, io, &read_buf);
    const json = try rdr.interface.allocRemaining(allocator, .limited(64 * 1024));
    defer allocator.free(json);
    const cbor_buf: []u8 = try allocator.alloc(u8, json.len);
    var bufs = std.ArrayListUnmanaged([]const u8).fromOwnedSlice(bufs_.*);
    bufs.append(allocator, cbor_buf) catch @panic("OOM:read_json_config_file");
    bufs_.* = bufs.toOwnedSlice(allocator) catch @panic("OOM:read_json_config_file");
    const cb = try cbor.fromJson(json, cbor_buf);
    var iter = cb;
    _ = try cbor.decodeMapHeader(&iter);
    return read_cbor_config(T, conf, file_name, iter);
}

fn read_cbor_config(
    T: type,
    conf: *T,
    file_name: []const u8,
    cb: []const u8,
) !void {
    var iter = cb;
    var field_name: []const u8 = undefined;
    while (cbor.matchString(&iter, &field_name) catch |e| switch (e) {
        error.TooShort => return,
        else => return e,
    }) {
        var known = false;
        inline for (@typeInfo(T).@"struct".fields) |field_info|
            if (comptime std.mem.eql(u8, "include_files", field_info.name)) {
                if (std.mem.eql(u8, field_name, field_info.name)) {
                    known = true;
                    var value: field_info.type = undefined;
                    if (try cbor.matchValue(&iter, cbor.extract(&value))) {
                        if (conf.include_files.len > 0) {
                            std.log.warn("{s}: ignoring nested 'include_files' value '{s}'", .{ file_name, value });
                        } else {
                            @field(conf, field_info.name) = value;
                        }
                    } else {
                        try cbor.skipValue(&iter);
                        std.log.err("invalid value for key '{s}'", .{field_name});
                    }
                }
            } else if (std.mem.eql(u8, field_name, field_info.name)) {
                known = true;
                var value: field_info.type = undefined;
                if (try cbor.matchValue(&iter, cbor.extract(&value))) {
                    @field(conf, field_info.name) = value;
                } else {
                    try cbor.skipValue(&iter);
                    std.log.err("invalid value for key '{s}'", .{field_name});
                }
            };
        if (!known) {
            try cbor.skipValue(&iter);
            std.log.warn("unknown config value '{s}' ignored", .{field_name});
        }
    }
}

fn read_nested_include_files(io: std.Io, T: type, allocator: std.mem.Allocator, conf: *T, bufs: *[][]const u8) void {
    if (conf.include_files.len == 0) return;
    var it = std.mem.splitScalar(u8, conf.include_files, std.fs.path.delimiter);
    while (it.next()) |path| if (!read_config_file(io, T, allocator, conf, bufs, path)) {
        std.log.warn("config include file '{s}' is not found", .{path});
    };
}

pub fn get_config_dir(io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    return get_app_config_dir(io, env, application_name);
}

pub const ConfigDirError = error{
    NoSpaceLeft,
    MakeConfigDirFailed,
    MakeHomeConfigDirFailed,
    MakeAppConfigDirFailed,
    AppConfigDirUnavailable,
};

fn get_app_config_dir(io: std.Io, env: *const std.process.Environ.Map, appname: []const u8) ConfigDirError![]const u8 {
    const local = struct {
        var config_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var config_dir: ?[]const u8 = null;
    };
    const config_dir = if (local.config_dir) |dir|
        dir
    else if (env.get("XDG_CONFIG_HOME")) |xdg| ret: {
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ xdg, appname });
    } else if (env.get("HOME")) |home| ret: {
        const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config", .{home});
        std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return error.MakeHomeConfigDirFailed,
        };
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config/{s}", .{ home, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (env.get("APPDATA")) |appdata| {
            const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ appdata, appname });
            std.Io.Dir.createDirAbsolute(io, dir, .default_dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return error.MakeAppConfigDirFailed,
            };
            break :ret dir;
        } else return error.AppConfigDirUnavailable;
    } else return error.AppConfigDirUnavailable;

    local.config_dir = config_dir;
    std.Io.Dir.createDirAbsolute(io, config_dir, .default_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return error.MakeConfigDirFailed,
    };

    var theme_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    std.Io.Dir.createDirAbsolute(io, try std.fmt.bufPrint(&theme_dir_buffer, "{s}/{s}", .{ config_dir, theme_dir }), .default_dir) catch {};

    return config_dir;
}

fn get_app_config_file_name(io: std.Io, env: *const std.process.Environ.Map, appname: []const u8, comptime base_name: []const u8) ConfigDirError![]const u8 {
    return get_app_config_dir_file_name(io, env, appname, base_name ++ ".json");
}

fn get_app_config_dir_file_name(io: std.Io, env: *const std.process.Environ.Map, appname: []const u8, comptime config_file_name: []const u8) ConfigDirError![]const u8 {
    const local = struct {
        var config_file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return std.fmt.bufPrint(&local.config_file_buffer, "{s}/{s}", .{ try get_app_config_dir(io, env, appname), config_file_name });
}

const theme_dir = "themes";

fn get_theme_directory(io: std.Io, env: *const std.process.Environ.Map) ![]const u8 {
    const local = struct {
        var dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    if (env.get("FLOW_THEMES_DIR")) |dir| {
        return try std.fmt.bufPrint(&local.dir_buffer, "{s}", .{dir});
    }
    return try std.fmt.bufPrint(&local.dir_buffer, "{s}/{s}", .{ try get_app_config_dir(io, env, application_name), theme_dir });
}

pub fn get_theme_file_name(io: std.Io, env: *const std.process.Environ.Map, theme_name: []const u8) ![]const u8 {
    const dir = try get_theme_directory(io, env);
    const local = struct {
        var file_buffer: [std.posix.PATH_MAX]u8 = undefined;
    };
    return try std.fmt.bufPrint(&local.file_buffer, "{s}/{s}.json", .{ dir, theme_name });
}

fn read_theme(io: std.Io, env: *const std.process.Environ.Map, allocator: std.mem.Allocator, theme_name: []const u8) ?[]const u8 {
    const file_name = get_theme_file_name(io, env, theme_name) catch return null;
    var file = std.Io.Dir.openFileAbsolute(io, file_name, .{ .mode = .read_only }) catch return null;
    defer file.close(io);
    var read_buf: [4096]u8 = undefined;
    var rdr = std.Io.File.reader(file, io, &read_buf);
    return rdr.interface.allocRemaining(allocator, .limited(64 * 1024)) catch null;
}

fn load_theme_file(io: std.Io, env: *const std.process.Environ.Map, allocator: std.mem.Allocator, theme_name: []const u8) !?std.json.Parsed(Theme) {
    return load_theme_file_internal(io, env, allocator, theme_name) catch |e| {
        std.log.err("loaded theme from file failed: {}", .{e});
        return e;
    };
}

fn load_theme_file_internal(io: std.Io, env: *const std.process.Environ.Map, allocator: std.mem.Allocator, theme_name: []const u8) !?std.json.Parsed(Theme) {
    _ = std.json.Scanner;
    const json_str = read_theme(io, env, allocator, theme_name) orelse return null;
    defer allocator.free(json_str);
    return try std.json.parseFromSlice(Theme, allocator, json_str, .{ .allocate = .alloc_always });
}

pub fn get_theme_by_name(io: std.Io, env: *const std.process.Environ.Map, allocator: std.mem.Allocator, name: []const u8) ?struct { Theme, ?std.json.Parsed(Theme) } {
    if (load_theme_file(io, env, allocator, name) catch null) |parsed_theme| {
        std.log.info("loaded theme from file: {s}", .{name});
        return .{ parsed_theme.value, parsed_theme };
    }

    std.log.info("loading theme: {s}", .{name});
    for (themes.themes) |theme_| {
        if (std.mem.eql(u8, theme_.name, name))
            return .{ theme_, null };
    }
    return null;
}
