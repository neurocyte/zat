const std = @import("std");

const eql = std.mem.eql;
const bufPrint = std.fmt.bufPrint;
const fixedBufferStream = std.io.fixedBufferStream;
const maxInt = std.math.maxInt;
const minInt = std.math.minInt;
const json = std.json;
const fba = std.heap.FixedBufferAllocator;

pub const CborError = error{
    CborIntegerTooLarge,
    CborIntegerTooSmall,
    CborInvalidType,
    CborTooShort,
    OutOfMemory,
};

pub const CborJsonError = error{
    BufferUnderrun,
    CborIntegerTooLarge,
    CborIntegerTooSmall,
    CborInvalidType,
    CborTooShort,
    CborUnsupportedType,
    NoSpaceLeft,
    OutOfMemory,
    Overflow,
    SyntaxError,
    UnexpectedEndOfInput,
};

const cbor_magic_null: u8 = 0xf6;
const cbor_magic_true: u8 = 0xf5;
const cbor_magic_false: u8 = 0xf4;

const cbor_magic_type_array: u8 = 4;
const cbor_magic_type_map: u8 = 5;

const value_type = enum(u8) {
    number,
    bytes,
    string,
    array,
    map,
    tag,
    boolean,
    null,
    any,
    more,
    unknown,
};
pub const number = value_type.number;
pub const bytes = value_type.bytes;
pub const string = value_type.string;
pub const array = value_type.array;
pub const map = value_type.map;
pub const tag = value_type.tag;
pub const boolean = value_type.boolean;
pub const null_ = value_type.null;
pub const any = value_type.any;
pub const more = value_type.more;

const null_value_buf = [_]u8{0xF6};
pub const null_value: []const u8 = &null_value_buf;

pub fn isNull(val: []const u8) bool {
    return eql(u8, val, null_value);
}

fn isAny(value: anytype) bool {
    return if (comptime @TypeOf(value) == value_type) value == value_type.any else false;
}

fn isMore(value: anytype) bool {
    return if (comptime @TypeOf(value) == value_type) value == value_type.more else false;
}

fn write(writer: anytype, value: u8) @TypeOf(writer).Error!void {
    _ = try writer.write(&[_]u8{value});
}

fn writeTypedVal(writer: anytype, type_: u8, value: u64) @TypeOf(writer).Error!void {
    const t: u8 = type_ << 5;
    if (value < 24) {
        try write(writer, t | @as(u8, @truncate(value)));
    } else if (value < 256) {
        try write(writer, t | 24);
        try write(writer, @as(u8, @truncate(value)));
    } else if (value < 65536) {
        try write(writer, t | 25);
        try write(writer, @as(u8, @truncate(value >> 8)));
        try write(writer, @as(u8, @truncate(value)));
    } else if (value < 4294967296) {
        try write(writer, t | 26);
        try write(writer, @as(u8, @truncate(value >> 24)));
        try write(writer, @as(u8, @truncate(value >> 16)));
        try write(writer, @as(u8, @truncate(value >> 8)));
        try write(writer, @as(u8, @truncate(value)));
    } else {
        try write(writer, t | 27);
        try write(writer, @as(u8, @truncate(value >> 56)));
        try write(writer, @as(u8, @truncate(value >> 48)));
        try write(writer, @as(u8, @truncate(value >> 40)));
        try write(writer, @as(u8, @truncate(value >> 32)));
        try write(writer, @as(u8, @truncate(value >> 24)));
        try write(writer, @as(u8, @truncate(value >> 16)));
        try write(writer, @as(u8, @truncate(value >> 8)));
        try write(writer, @as(u8, @truncate(value)));
    }
}

pub fn writeArrayHeader(writer: anytype, sz: usize) @TypeOf(writer).Error!void {
    return writeTypedVal(writer, cbor_magic_type_array, sz);
}

pub fn writeMapHeader(writer: anytype, sz: usize) @TypeOf(writer).Error!void {
    return writeTypedVal(writer, cbor_magic_type_map, sz);
}

pub fn writeArray(writer: anytype, args: anytype) @TypeOf(writer).Error!void {
    const args_type_info = @typeInfo(@TypeOf(args));
    if (args_type_info != .Struct) @compileError("expected tuple or struct argument");
    const fields_info = args_type_info.Struct.fields;
    try writeArrayHeader(writer, fields_info.len);
    inline for (fields_info) |field_info|
        try writeValue(writer, @field(args, field_info.name));
}

fn writeI64(writer: anytype, value: i64) @TypeOf(writer).Error!void {
    return if (value < 0)
        writeTypedVal(writer, 1, @as(u64, @bitCast(-(value + 1))))
    else
        writeTypedVal(writer, 0, @as(u64, @bitCast(value)));
}

fn writeU64(writer: anytype, value: u64) @TypeOf(writer).Error!void {
    return writeTypedVal(writer, 0, value);
}

fn writeString(writer: anytype, s: []const u8) @TypeOf(writer).Error!void {
    try writeTypedVal(writer, 3, s.len);
    _ = try writer.write(s);
}

fn writeBool(writer: anytype, value: bool) @TypeOf(writer).Error!void {
    return write(writer, if (value) cbor_magic_true else cbor_magic_false);
}

fn writeNull(writer: anytype) @TypeOf(writer).Error!void {
    return write(writer, cbor_magic_null);
}

fn writeErrorset(writer: anytype, err: anyerror) @TypeOf(writer).Error!void {
    var buf: [256]u8 = undefined;
    const errmsg = try bufPrint(&buf, "error.{s}", .{@errorName(err)});
    return writeString(writer, errmsg);
}

pub fn writeValue(writer: anytype, value: anytype) @TypeOf(writer).Error!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .Int, .ComptimeInt => return if (T == u64) writeU64(writer, value) else writeI64(writer, @intCast(value)),
        .Bool => return writeBool(writer, value),
        .Optional => return if (value) |v| writeValue(writer, v) else writeNull(writer),
        .ErrorUnion => return if (value) |v| writeValue(writer, v) else |err| writeValue(writer, err),
        .ErrorSet => return writeErrorset(writer, value),
        .Union => |info| {
            if (info.tag_type) |TagType| {
                comptime var v = void;
                inline for (info.fields) |u_field| {
                    if (value == @field(TagType, u_field.name))
                        v = @field(value, u_field.name);
                }
                try writeArray(writer, .{
                    @typeName(T),
                    @tagName(@as(TagType, value)),
                    v,
                });
            } else {
                try writeArray(writer, .{@typeName(T)});
            }
        },
        .Struct => |info| {
            if (info.is_tuple) {
                if (info.fields.len == 0) return writeNull(writer);
                try writeArrayHeader(writer, info.fields.len);
                inline for (info.fields) |f|
                    try writeValue(writer, @field(value, f.name));
            } else {
                if (info.fields.len == 0) return writeNull(writer);
                try writeMapHeader(writer, info.fields.len);
                inline for (info.fields) |f| {
                    try writeString(writer, f.name);
                    try writeValue(writer, @field(value, f.name));
                }
            }
        },
        .Pointer => |ptr_info| switch (ptr_info.size) {
            .One => return writeValue(writer, value.*),
            .Many, .C => @compileError("cannot write type '" ++ @typeName(T) ++ "' to cbor stream"),
            .Slice => {
                if (ptr_info.child == u8) return writeString(writer, value);
                if (value.len == 0) return writeNull(writer);
                try writeArrayHeader(writer, value.len);
                for (value) |elem|
                    try writeValue(writer, elem);
            },
        },
        .Array => |info| {
            if (info.child == u8) return writeString(writer, &value);
            if (value.len == 0) return writeNull(writer);
            try writeArrayHeader(writer, value.len);
            for (value) |elem|
                try writeValue(writer, elem);
        },
        .Vector => |info| {
            try writeArrayHeader(writer, info.len);
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                try writeValue(writer, value[i]);
            }
        },
        .Null => try writeNull(writer),
        else => @compileError("cannot write type '" ++ @typeName(T) ++ "' to cbor stream"),
    }
}

pub fn fmt(buf: []u8, value: anytype) []const u8 {
    var stream = fixedBufferStream(buf);
    writeValue(stream.writer(), value) catch unreachable;
    return stream.getWritten();
}

const CborType = struct { type: u8, minor: u5, major: u3 };

pub fn decodeType(iter: *[]const u8) error{CborTooShort}!CborType {
    if (iter.len < 1)
        return error.CborTooShort;
    const type_: u8 = iter.*[0];
    const bits: packed struct { minor: u5, major: u3 } = @bitCast(type_);
    iter.* = iter.*[1..];
    return .{ .type = type_, .minor = bits.minor, .major = bits.major };
}

fn decodeUIntLengthRecurse(iter: *[]const u8, length: usize, acc: u64) !u64 {
    if (iter.len < 1)
        return error.CborTooShort;
    const v: u8 = iter.*[0];
    iter.* = iter.*[1..];
    var i = acc | v;
    if (length == 1)
        return i;
    i <<= 8;
    // return @call(.always_tail, decodeUIntLengthRecurse, .{ iter, length - 1, i });  FIXME: @call(.always_tail) seems broken as of 0.11.0-dev.2964+e9cbdb2cf
    return decodeUIntLengthRecurse(iter, length - 1, i);
}

fn decodeUIntLength(iter: *[]const u8, length: usize) !u64 {
    return decodeUIntLengthRecurse(iter, length, 0);
}

fn decodePInt(iter: *[]const u8, minor: u5) !u64 {
    if (minor < 24) return minor;
    return switch (minor) {
        24 => decodeUIntLength(iter, 1), // 1 byte
        25 => decodeUIntLength(iter, 2), // 2 byte
        26 => decodeUIntLength(iter, 4), // 4 byte
        27 => decodeUIntLength(iter, 8), // 8 byte
        else => error.CborInvalidType,
    };
}

fn decodeNInt(iter: *[]const u8, minor: u5) CborError!i64 {
    return -@as(i64, @intCast(try decodePInt(iter, minor) + 1));
}

pub fn decodeMapHeader(iter: *[]const u8) CborError!usize {
    const t = try decodeType(iter);
    if (t.type == cbor_magic_null)
        return 0;
    if (t.major != 5)
        return error.CborInvalidType;
    return decodePInt(iter, t.minor);
}

pub fn decodeArrayHeader(iter: *[]const u8) CborError!usize {
    const t = try decodeType(iter);
    if (t.type == cbor_magic_null)
        return 0;
    if (t.major != 4)
        return error.CborInvalidType;
    return decodePInt(iter, t.minor);
}

fn decodeString(iter_: *[]const u8, minor: u5) CborError![]const u8 {
    var iter = iter_.*;
    const len = try decodePInt(&iter, minor);
    if (iter.len < len)
        return error.CborTooShort;
    const s = iter[0..len];
    iter = iter[len..];
    iter_.* = iter;
    return s;
}

fn decodeBytes(iter: *[]const u8, minor: u5) CborError![]const u8 {
    return decodeString(iter, minor);
}

fn decodeJsonArray(iter_: *[]const u8, minor: u5, arr: *json.Array) CborError!bool {
    var iter = iter_.*;
    var n = try decodePInt(&iter, minor);
    while (n > 0) {
        const value = try arr.addOne();
        if (!try matchJsonValue(&iter, value, arr.allocator))
            return false;
        n -= 1;
    }
    iter_.* = iter;
    return true;
}

fn decodeJsonObject(iter_: *[]const u8, minor: u5, obj: *json.ObjectMap) CborError!bool {
    var iter = iter_.*;
    var n = try decodePInt(&iter, minor);
    while (n > 0) {
        var key: []u8 = undefined;
        var value: json.Value = .null;

        if (!try matchString(&iter, &key))
            return false;
        if (!try matchJsonValue(&iter, &value, obj.allocator))
            return false;

        _ = try obj.getOrPutValue(key, value);
        n -= 1;
    }
    iter_.* = iter;
    return true;
}

pub fn matchInt(comptime T: type, iter_: *[]const u8, val: *T) CborError!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    val.* = switch (t.major) {
        0 => blk: { // positive integer
            const v = try decodePInt(&iter, t.minor);
            if (v > maxInt(T))
                return error.CborIntegerTooLarge;
            break :blk @intCast(v);
        },
        1 => blk: { // negative integer
            const v = try decodeNInt(&iter, t.minor);
            if (v < minInt(T))
                return error.CborIntegerTooSmall;
            break :blk @intCast(v);
        },

        else => return false,
    };
    iter_.* = iter;
    return true;
}

pub fn matchIntValue(comptime T: type, iter: *[]const u8, val: T) CborError!bool {
    var v: T = 0;
    return if (try matchInt(T, iter, &v)) v == val else false;
}

pub fn matchBool(iter_: *[]const u8, v: *bool) CborError!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    if (t.major == 7) { // special
        if (t.type == cbor_magic_false) {
            v.* = false;
            iter_.* = iter;
            return true;
        }
        if (t.type == cbor_magic_true) {
            v.* = true;
            iter_.* = iter;
            return true;
        }
    }
    return false;
}

fn matchBoolValue(iter: *[]const u8, val: bool) CborError!bool {
    var v: bool = false;
    return if (try matchBool(iter, &v)) v == val else false;
}

fn skipString(iter: *[]const u8, minor: u5) CborError!void {
    const len = try decodePInt(iter, minor);
    if (iter.len < len)
        return error.CborTooShort;
    iter.* = iter.*[len..];
}

fn skipBytes(iter: *[]const u8, minor: u5) CborError!void {
    return skipString(iter, minor);
}

fn skipArray(iter: *[]const u8, minor: u5) CborError!void {
    var len = try decodePInt(iter, minor);
    while (len > 0) {
        try skipValue(iter);
        len -= 1;
    }
}

fn skipMap(iter: *[]const u8, minor: u5) CborError!void {
    var len = try decodePInt(iter, minor);
    len *= 2;
    while (len > 0) {
        try skipValue(iter);
        len -= 1;
    }
}

pub fn skipValue(iter: *[]const u8) CborError!void {
    const t = try decodeType(iter);
    try skipValueType(iter, t.major, t.minor);
}

fn skipValueType(iter: *[]const u8, major: u3, minor: u5) CborError!void {
    switch (major) {
        0 => { // positive integer
            _ = try decodePInt(iter, minor);
        },
        1 => { // negative integer
            _ = try decodeNInt(iter, minor);
        },
        2 => { // bytes
            try skipBytes(iter, minor);
        },
        3 => { // string
            try skipString(iter, minor);
        },
        4 => { // array
            try skipArray(iter, minor);
        },
        5 => { // map
            try skipMap(iter, minor);
        },
        6 => { // tag
            return error.CborInvalidType;
        },
        7 => { // special
            return;
        },
    }
}

fn matchType(iter_: *[]const u8, v: *value_type) CborError!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    try skipValueType(&iter, t.major, t.minor);
    switch (t.major) {
        0, 1 => v.* = value_type.number, // positive integer or negative integer
        2 => v.* = value_type.bytes, // bytes
        3 => v.* = value_type.string, // string
        4 => v.* = value_type.array, // array
        5 => v.* = value_type.map, // map
        7 => { // special
            if (t.type == cbor_magic_null) {
                v.* = value_type.null;
            } else {
                if (t.type == cbor_magic_false or t.type == cbor_magic_true) {
                    v.* = value_type.boolean;
                } else {
                    return false;
                }
            }
        },
        else => return false,
    }
    iter_.* = iter;
    return true;
}

fn matchValueType(iter: *[]const u8, t: value_type) CborError!bool {
    var v: value_type = value_type.unknown;
    return if (try matchType(iter, &v)) (t == value_type.any or t == v) else false;
}

pub fn matchString(iter_: *[]const u8, val: *[]const u8) CborError!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    val.* = switch (t.major) {
        2 => try decodeBytes(&iter, t.minor), // bytes
        3 => try decodeString(&iter, t.minor), // string
        else => return false,
    };
    iter_.* = iter;
    return true;
}

fn matchStringValue(iter: *[]const u8, lit: []const u8) CborError!bool {
    var val: []const u8 = undefined;
    return if (try matchString(iter, &val)) eql(u8, val, lit) else false;
}

fn matchError(comptime T: type) noreturn {
    @compileError("cannot match type '" ++ @typeName(T) ++ "' to cbor stream");
}

pub fn matchValue(iter: *[]const u8, value: anytype) CborError!bool {
    if (@TypeOf(value) == value_type)
        return matchValueType(iter, value);
    const T = comptime @TypeOf(value);
    if (comptime isExtractor(T))
        return value.extract(iter);
    return switch (comptime @typeInfo(T)) {
        .Int => return matchIntValue(T, iter, value),
        .ComptimeInt => return matchIntValue(i64, iter, value),
        .Bool => matchBoolValue(iter, value),
        .Pointer => |info| switch (info.size) {
            .One => matchValue(iter, value.*),
            .Many, .C => matchError(T),
            .Slice => if (info.child == u8) matchStringValue(iter, value) else matchArray(iter, value, info),
        },
        .Struct => |info| if (info.is_tuple)
            matchArray(iter, value, info)
        else
            matchError(T),
        .Array => |info| if (info.child == u8) matchStringValue(iter, &value) else matchArray(iter, value, info),
        else => @compileError("cannot match value type '" ++ @typeName(T) ++ "' to cbor stream"),
    };
}

fn matchJsonValue(iter_: *[]const u8, v: *json.Value, a: std.mem.Allocator) CborError!bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    const ret = switch (t.major) {
        0 => ret: { // positive integer
            v.* = json.Value{ .integer = @intCast(try decodePInt(&iter, t.minor)) };
            break :ret true;
        },
        1 => ret: { // negative integer
            v.* = json.Value{ .integer = try decodeNInt(&iter, t.minor) };
            break :ret true;
        },
        2 => ret: { // bytes
            break :ret false;
        },
        3 => ret: { // string
            v.* = json.Value{ .string = try decodeString(&iter, t.minor) };
            break :ret true;
        },
        4 => ret: { // array
            v.* = json.Value{ .array = json.Array.init(a) };
            break :ret try decodeJsonArray(&iter, t.minor, &v.array);
        },
        5 => ret: { // map
            v.* = json.Value{ .object = json.ObjectMap.init(a) };
            break :ret try decodeJsonObject(&iter, t.minor, &v.object);
        },
        6 => ret: { // tag
            break :ret false;
        },
        7 => ret: { // special
            switch (t.type) {
                cbor_magic_false => {
                    v.* = json.Value{ .bool = false };
                    break :ret true;
                },
                cbor_magic_true => {
                    v.* = json.Value{ .bool = true };
                    break :ret true;
                },
                cbor_magic_null => {
                    v.* = json.Value{ .null = {} };
                    break :ret true;
                },
                else => break :ret false,
            }
        },
    };
    if (ret) iter_.* = iter;
    return ret;
}

fn matchArrayMore(iter_: *[]const u8, n_: u64) CborError!bool {
    var iter = iter_.*;
    var n = n_;
    while (n > 0) {
        if (!try matchValue(&iter, value_type.any))
            return false;
        n -= 1;
    }
    iter_.* = iter;
    return true;
}

fn matchArray(iter_: *[]const u8, arr: anytype, info: anytype) CborError!bool {
    var iter = iter_.*;
    var n = try decodeArrayHeader(&iter);
    inline for (info.fields) |f| {
        const value = @field(arr, f.name);
        if (isMore(value))
            break;
    } else if (info.fields.len != n)
        return false;
    inline for (info.fields) |f| {
        const value = @field(arr, f.name);
        if (isMore(value))
            return matchArrayMore(&iter, n);
        if (n == 0) return false;
        const matched = try matchValue(&iter, @field(arr, f.name));
        if (!matched) return false;
        n -= 1;
    }
    if (n == 0) iter_.* = iter;
    return n == 0;
}

fn matchJsonObject(iter_: *[]const u8, obj: *json.ObjectMap) !bool {
    var iter = iter_.*;
    const t = try decodeType(&iter);
    if (t.type == cbor_magic_null)
        return true;
    if (t.major != 5)
        return error.CborInvalidType;
    const ret = try decodeJsonObject(&iter, t.minor, obj);
    if (ret) iter_.* = iter;
    return ret;
}

pub fn match(buf: []const u8, pattern: anytype) CborError!bool {
    var iter: []const u8 = buf;
    return matchValue(&iter, pattern);
}

fn extractError(comptime T: type) noreturn {
    @compileError("cannot extract type '" ++ @typeName(T) ++ "' from cbor stream");
}

fn hasExtractorTag(info: anytype) bool {
    if (info.is_tuple) return false;
    inline for (info.decls) |decl| {
        if (comptime eql(u8, decl.name, "EXTRACTOR_TAG"))
            return true;
    }
    return false;
}

fn isExtractor(comptime T: type) bool {
    return comptime switch (@typeInfo(T)) {
        .Struct => |info| hasExtractorTag(info),
        else => false,
    };
}

const JsonValueExtractor = struct {
    dest: *T,
    const Self = @This();
    pub const EXTRACTOR_TAG = struct {};
    const T = json.Value;

    pub fn init(dest: *T) Self {
        return .{ .dest = dest };
    }

    pub fn extract(self: Self, iter: *[]const u8) CborError!bool {
        var null_heap_: [0]u8 = undefined;
        var heap = fba.init(&null_heap_);
        return matchJsonValue(iter, self.dest, heap.allocator());
    }
};

const JsonObjectExtractor = struct {
    dest: *T,
    const Self = @This();
    pub const EXTRACTOR_TAG = struct {};
    const T = json.ObjectMap;

    pub fn init(dest: *T) Self {
        return .{ .dest = dest };
    }

    pub fn extract(self: Self, iter: *[]const u8) CborError!bool {
        return matchJsonObject(iter, self.dest);
    }
};

fn Extractor(comptime T: type) type {
    if (T == json.Value)
        return JsonValueExtractor;
    if (T == json.ObjectMap)
        return JsonObjectExtractor;
    return struct {
        dest: *T,
        const Self = @This();
        pub const EXTRACTOR_TAG = struct {};

        pub fn init(dest: *T) Self {
            return .{ .dest = dest };
        }

        pub fn extract(self: Self, iter: *[]const u8) CborError!bool {
            switch (comptime @typeInfo(T)) {
                .Int, .ComptimeInt => return matchInt(T, iter, self.dest),
                .Bool => return matchBool(iter, self.dest),
                .Pointer => |ptr_info| switch (ptr_info.size) {
                    .Slice => {
                        if (ptr_info.child == u8) return matchString(iter, self.dest) else extractError(T);
                    },
                    else => extractError(T),
                },
                else => extractError(T),
            }
        }
    };
}

fn ExtractorType(comptime T: type) type {
    const T_type_info = @typeInfo(T);
    if (T_type_info != .Pointer) @compileError("extract requires a pointer argument");
    return Extractor(T_type_info.Pointer.child);
}

pub fn extract(dest: anytype) ExtractorType(@TypeOf(dest)) {
    comptime {
        if (!isExtractor(ExtractorType(@TypeOf(dest))))
            @compileError("isExtractor self check failed for " ++ @typeName(ExtractorType(@TypeOf(dest))));
    }
    return ExtractorType(@TypeOf(dest)).init(dest);
}

const CborExtractor = struct {
    dest: *[]const u8,
    const Self = @This();
    pub const EXTRACTOR_TAG = struct {};

    pub fn init(dest: *[]const u8) Self {
        return .{ .dest = dest };
    }

    pub fn extract(self: Self, iter: *[]const u8) CborError!bool {
        const b = iter.*;
        try skipValue(iter);
        self.dest.* = b[0..(b.len - iter.len)];
        return true;
    }
};

pub fn extract_cbor(dest: *[]const u8) CborExtractor {
    return CborExtractor.init(dest);
}

pub fn JsonStream(comptime T: type) type {
    return struct {
        const Writer = T.Writer;
        const JsonWriter = json.WriteStream(Writer, .{ .checked_to_fixed_depth = 256 });

        fn jsonWriteArray(w: *JsonWriter, iter: *[]const u8, minor: u5) !void {
            var count = try decodePInt(iter, minor);
            try w.beginArray();
            while (count > 0) : (count -= 1) {
                try jsonWriteValue(w, iter);
            }
            try w.endArray();
        }

        fn jsonWriteMap(w: *JsonWriter, iter: *[]const u8, minor: u5) !void {
            var count = try decodePInt(iter, minor);
            try w.beginObject();
            while (count > 0) : (count -= 1) {
                const t = try decodeType(iter);
                if (t.major != 3) return error.CborInvalidType;
                try w.objectField(try decodeString(iter, t.minor));
                try jsonWriteValue(w, iter);
            }
            try w.endObject();
        }

        pub fn jsonWriteValue(w: *JsonWriter, iter: *[]const u8) (CborJsonError || Writer.Error)!void {
            const t = try decodeType(iter);
            if (t.type == cbor_magic_false)
                return w.write(false);
            if (t.type == cbor_magic_true)
                return w.write(true);
            if (t.type == cbor_magic_null)
                return w.write(null);
            return switch (t.major) {
                0 => w.write(try decodePInt(iter, t.minor)), // positive integer
                1 => w.write(try decodeNInt(iter, t.minor)), // negative integer
                2 => error.CborUnsupportedType, // bytes
                3 => w.write(try decodeString(iter, t.minor)), // string
                4 => jsonWriteArray(w, iter, t.minor), // array
                5 => jsonWriteMap(w, iter, t.minor), // map
                else => error.CborInvalidType,
            };
        }
    };
}

pub fn toJson(cbor_buf: []const u8, json_buf: []u8) CborJsonError![]const u8 {
    var fbs = fixedBufferStream(json_buf);
    var s = json.writeStream(fbs.writer(), .{});
    var iter: []const u8 = cbor_buf;
    try JsonStream(@TypeOf(fbs)).jsonWriteValue(&s, &iter);
    return fbs.getWritten();
}

pub fn toJsonPretty(cbor_buf: []const u8, json_buf: []u8) CborJsonError![]const u8 {
    var fbs = fixedBufferStream(json_buf);
    var s = json.writeStream(fbs.writer(), .{ .whitespace = .indent_1 });
    var iter: []const u8 = cbor_buf;
    try JsonStream(@TypeOf(fbs)).jsonWriteValue(&s, &iter);
    return fbs.getWritten();
}

fn writeJsonValue(writer: anytype, value: json.Value) !void {
    try switch (value) {
        .array => |_| unreachable,
        .object => |_| unreachable,
        .null => writeNull(writer),
        .float => |_| error.CborUnsupportedType,
        inline else => |v| writeValue(writer, v),
    };
}

fn jsonScanUntil(writer: anytype, scanner: *json.Scanner, end_token: anytype) CborJsonError!usize {
    var partial = try std.BoundedArray(u8, 4096).init(0);
    var count: usize = 0;

    var token = try scanner.next();
    while (token != end_token) : (token = try scanner.next()) {
        count += 1;
        switch (token) {
            .object_begin => try writeJsonObject(writer, scanner),
            .array_begin => try writeJsonArray(writer, scanner),

            .true => try writeBool(writer, true),
            .false => try writeBool(writer, false),
            .null => try writeNull(writer),

            .number => |v| {
                try partial.appendSlice(v);
                try writeJsonValue(writer, json.Value.parseFromNumberSlice(partial.slice()));
                try partial.resize(0);
            },
            .partial_number => |v| {
                try partial.appendSlice(v);
                count -= 1;
            },

            .string => |v| {
                try partial.appendSlice(v);
                try writeString(writer, partial.slice());
                try partial.resize(0);
            },
            .partial_string => |v| {
                try partial.appendSlice(v);
                count -= 1;
            },
            .partial_string_escaped_1 => |v| {
                try partial.appendSlice(&v);
                count -= 1;
            },
            .partial_string_escaped_2 => |v| {
                try partial.appendSlice(&v);
                count -= 1;
            },
            .partial_string_escaped_3 => |v| {
                try partial.appendSlice(&v);
                count -= 1;
            },
            .partial_string_escaped_4 => |v| {
                try partial.appendSlice(&v);
                count -= 1;
            },

            else => return error.SyntaxError,
        }
    }
    return count;
}

pub const local_heap_size = 4096 * 16;

fn writeJsonArray(writer_: anytype, scanner: *json.Scanner) CborJsonError!void {
    var buf: [local_heap_size]u8 = undefined;
    var stream = fixedBufferStream(&buf);
    const writer = stream.writer();
    const count = try jsonScanUntil(writer, scanner, .array_end);
    try writeArrayHeader(writer_, count);
    try writer_.writeAll(stream.getWritten());
}

fn writeJsonObject(writer_: anytype, scanner: *json.Scanner) CborJsonError!void {
    var buf: [local_heap_size]u8 = undefined;
    var stream = fixedBufferStream(&buf);
    const writer = stream.writer();
    const count = try jsonScanUntil(writer, scanner, .object_end);
    try writeMapHeader(writer_, count / 2);
    try writer_.writeAll(stream.getWritten());
}

pub fn fromJson(json_buf: []const u8, cbor_buf: []u8) ![]const u8 {
    var local_heap_: [local_heap_size]u8 = undefined;
    var heap = fba.init(&local_heap_);
    var stream = fixedBufferStream(cbor_buf);
    const writer = stream.writer();

    var scanner = json.Scanner.initCompleteInput(heap.allocator(), json_buf);
    defer scanner.deinit();

    _ = try jsonScanUntil(writer, &scanner, .end_of_document);
    return stream.getWritten();
}
