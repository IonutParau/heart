const std = @import("std");
const lua = @cImport({
    @cInclude("lua/lua.h");
    @cInclude("lua/lualib.h");
    @cInclude("lua/lauxlib.h");
});

const Allocator = std.mem.Allocator;

// Caller owns the memory!!!! Those string slices are copies!!!
pub fn findRequires(vm: *lua.lua_State, code: []const u8, allocator: Allocator) !std.ArrayList([]const u8) {
    const pattern =
        \\require%s*%(?['"]([%a%s_%.]*)['"]%s*%)?
    ;

    _ = lua.lua_getglobal(vm, "string");
    _ = lua.lua_getfield(vm, -1, "gmatch");
    var codec: [:0]u8 = try allocator.allocSentinel(u8, code.len, 0);
    defer allocator.free(codec);

    @memcpy(codec, code);
    _ = lua.lua_pushstring(vm, codec.ptr);
    _ = lua.lua_pushstring(vm, pattern);
    lua.lua_callk(vm, 2, 1, 0, null);

    var requires = std.ArrayList([]const u8).init(allocator);
    errdefer requires.deinit();

    while (true) {
        lua.lua_pushnil(vm);
        lua.lua_copy(vm, -2, -1);
        lua.lua_callk(vm, 0, 1, 0, null);
        if (lua.lua_isnoneornil(vm, -1)) {
            _ = lua.lua_pop(vm, 1);
            break;
        }
        var l: usize = 0;
        var cstr = lua.luaL_tolstring(vm, -1, &l);
        defer lua.lua_pop(vm, 1);
        var str = try allocator.alloc(u8, l);
        errdefer allocator.free(str);
        var cstrbuf: []const u8 = undefined;
        cstrbuf.ptr = cstr;
        cstrbuf.len = l;
        @memcpy(str, cstrbuf);
        try requires.append(str);
        _ = lua.lua_pop(vm, 1);
    }
    _ = lua.lua_pop(vm, 1);

    return requires;
}

pub const FileStore = std.StringHashMap(void);

const fs = std.fs;

pub fn addDependencies(vm: *lua.lua_State, store: *FileStore, path: []const u8, allocator: Allocator) !void {
    if (std.mem.count(u8, path, ".") == 0) {
        // Assume directory
        var dir = try fs.cwd().openIterableDir(path, fs.Dir.OpenDirOptions{});
        defer dir.close();
        var iter = dir.iterate();

        while (try iter.next()) |f| {
            const Entry = fs.IterableDir.Entry;
            const entry: Entry = f;
            try addDependencies(vm, store, entry.name, allocator);
        }

        return;
    }
    var file = fs.cwd().openFile(path, fs.File.OpenFlags{}) catch return; // if file does not exist or is inaccessible, do nothing
    defer file.close();

    try store.put(try allocator.dupe(u8, path), {});

    var code = try file.readToEndAlloc(allocator, (try file.stat()).size);
    defer allocator.free(code);

    var reqs = try findRequires(vm, code, allocator);
    defer reqs.deinit();

    defer for (reqs.items) |req| {
        allocator.free(req);
    };

    for (reqs.items) |req| {
        var reqpath = try allocator.dupe(u8, req);
        defer allocator.free(reqpath);

        for (reqpath, 0..) |c, i| {
            if (c == '.') {
                reqpath[i] = fs.path.sep;
            }
        }

        if (fs.cwd().openIterableDir(reqpath, fs.Dir.OpenDirOptions{})) |d| {
            var dir = d;
            defer dir.close();

            // Iterate and add
            var iter = dir.iterate();

            while (try iter.next()) |f| {
                const Entry = fs.IterableDir.Entry;
                const entry: Entry = f;
                var fpath = try fs.path.join(allocator, &[_][]const u8{ reqpath, entry.name });
                defer allocator.free(fpath);
                try addDependencies(vm, store, fpath, allocator);
            }
        } else |_| {
            var f = try std.mem.concat(allocator, u8, &[_][]const u8{ reqpath, ".lua" });
            defer allocator.free(f);

            return addDependencies(vm, store, f, allocator);
        }
    }
}
