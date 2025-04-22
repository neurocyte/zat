const std = @import("std");
const cbor = @import("cbor");
const builtin = @import("builtin");

const application_name = "flow";

const config = struct {
    theme: []const u8 = "default",
};

pub fn read_config(a: std.mem.Allocator, buf: *?[]const u8) config {
    const file_name = get_app_config_file_name(application_name) catch return .{};
    return read_json_config_file(a, file_name, buf) catch .{};
}

fn read_json_config_file(a: std.mem.Allocator, file_name: []const u8, buf: *?[]const u8) !config {
    var file = std.fs.openFileAbsolute(file_name, .{ .mode = .read_only }) catch |e| switch (e) {
        error.FileNotFound => return .{},
        else => return e,
    };
    defer file.close();
    const json = try file.readToEndAlloc(a, 64 * 1024);
    defer a.free(json);
    const cbor_buf: []u8 = try a.alloc(u8, json.len);
    buf.* = cbor_buf;
    const cb = try cbor.fromJson(json, cbor_buf);
    var iter = cb;
    var len = try cbor.decodeMapHeader(&iter);
    var data: config = .{};
    while (len > 0) : (len -= 1) {
        var found = false;
        var field_name: []const u8 = undefined;
        if (!(try cbor.matchString(&iter, &field_name))) return error.InvalidConfig;
        inline for (@typeInfo(config).@"struct".fields) |field_info| {
            if (std.mem.eql(u8, field_name, field_info.name)) {
                var value: field_info.type = undefined;
                if (!(try cbor.matchValue(&iter, cbor.extract(&value)))) return error.InvalidConfig;
                @field(data, field_info.name) = value;
                found = true;
            }
        }
        if (!found) try cbor.skipValue(&iter);
    }
    return data;
}

pub fn get_config_dir() ![]const u8 {
    return get_app_config_dir(application_name);
}

fn get_app_config_dir(appname: []const u8) ![]const u8 {
    const a = std.heap.c_allocator;
    const local = struct {
        var config_dir_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var config_dir: ?[]const u8 = null;
    };
    const config_dir = if (local.config_dir) |dir|
        dir
    else if (std.process.getEnvVarOwned(a, "XDG_CONFIG_HOME") catch null) |xdg| ret: {
        defer a.free(xdg);
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ xdg, appname });
    } else if (std.process.getEnvVarOwned(a, "HOME") catch null) |home| ret: {
        defer a.free(home);
        const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config", .{home});
        std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
            error.PathAlreadyExists => {},
            else => return e,
        };
        break :ret try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/.config/{s}", .{ home, appname });
    } else if (builtin.os.tag == .windows) ret: {
        if (std.process.getEnvVarOwned(a, "APPDATA") catch null) |appdata| {
            defer a.free(appdata);
            const dir = try std.fmt.bufPrint(&local.config_dir_buffer, "{s}/{s}", .{ appdata, appname });
            std.fs.makeDirAbsolute(dir) catch |e| switch (e) {
                error.PathAlreadyExists => {},
                else => return e,
            };
            break :ret dir;
        } else return error.AppConfigDirUnavailable;
    } else return error.AppConfigDirUnavailable;

    local.config_dir = config_dir;
    std.fs.makeDirAbsolute(config_dir) catch |e| switch (e) {
        error.PathAlreadyExists => {},
        else => return e,
    };
    return config_dir;
}

fn get_app_config_file_name(appname: []const u8) ![]const u8 {
    const local = struct {
        var config_file_buffer: [std.posix.PATH_MAX]u8 = undefined;
        var config_file: ?[]const u8 = null;
    };
    const config_file_name = "config.json";
    const config_file = if (local.config_file) |file|
        file
    else
        try std.fmt.bufPrint(&local.config_file_buffer, "{s}/{s}", .{ try get_app_config_dir(appname), config_file_name });
    local.config_file = config_file;
    return config_file;
}
