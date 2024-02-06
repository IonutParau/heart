const std = @import("std");
const regex = @import("zigregex/src/regex.zig");
const lua = @cImport({
    @cInclude("lua/lua.h");
    @cInclude("lua/lualib.h");
    @cInclude("lua/lauxlib.h");
});
const Regex = regex.Regex;

const Allocator = std.mem.Allocator;

// Caller owns the memory!!!! Those string slices are copies!!!
pub fn findRequires(vm: *lua.lua_State, code: []const u8, allocator: Allocator) ![][]const u8 {
    const pattern =
        \\require%s*%(?['"]([%a%s_%.]*)['"]%s*%)?
    ;

    _ = lua.lua_getglobal(vm, "string");
    _ = lua.lua_getfield(vm, -1, "gmatch");
    var codec: [:0]u8 = try allocator.allocSentinel(u8, code.len, 0);
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

    return requires.items;
}
