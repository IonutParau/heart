const std = @import("std");
const lua = @cImport({
    @cInclude("lua/lua.h");
    @cInclude("lua/lualib.h");
    @cInclude("lua/lauxlib.h");
});

const Allocator = std.mem.Allocator;

const Dependency = struct {
    url: []const u8,
    module: []const u8,
    parts: []const []const u8,
};

fn getDependencies(vm: *lua.lua_State, allocator: Allocator) ![]const Dependency {
    var deps = std.ArrayList(Dependency).init(allocator);
    var i: usize = 0;

    while (true) {
        i += 1;
        _ = lua.lua_geti(vm, -1, @intCast(i));
        if (lua.lua_isnoneornil(vm, -1)) {
            _ = lua.lua_pop(vm, 1);
            break;
        }

        var url: []const u8 = undefined;
        _ = lua.lua_geti(vm, -1, 1);
        var c_url = lua.lua_tolstring(vm, -1, null);
        _ = lua.lua_pop(vm, 1);
        url.ptr = c_url;
        url.len = std.mem.len(c_url);

        var module: []const u8 = undefined;
        _ = lua.lua_getfield(vm, -1, "module");
        var default_module: [*c]const u8 = c_url;
        if (std.mem.lastIndexOf(u8, url, "/")) |idx| {
            var str = url[(idx + 1)..]; // for foo/bar, this is bar
            var cstr = try allocator.allocSentinel(u8, str.len, 0);
            @memcpy(cstr, str);
            default_module = cstr;
        }
        var c_module: [*c]const u8 = "";
        if (lua.lua_isnoneornil(vm, -1)) {
            _ = lua.lua_pop(vm, 1);
            c_module = default_module;
        } else {
            c_module = lua.lua_tolstring(vm, -1, null);
            _ = lua.lua_pop(vm, 1);
        }

        module.ptr = c_module;
        module.len = std.mem.len(c_module);

        var parts = std.ArrayList([]const u8).init(allocator);

        _ = lua.lua_getfield(vm, -1, "parts");
        if (lua.lua_istable(vm, -1)) {
            var j: usize = 0;

            while (true) {
                _ = lua.lua_geti(vm, -1, @intCast(j));
                if (lua.lua_isnoneornil(vm, -1)) {
                    _ = lua.lua_pop(vm, 1);
                    break;
                }

                var part: []const u8 = undefined;
                var c_part = lua.lua_tolstring(vm, -1, null);
                part.ptr = c_part;
                part.len = std.mem.len(c_part);

                try parts.append(part);

                _ = lua.lua_pop(vm, 1);
            }
        } else {
            _ = lua.lua_pop(vm, 1);
        }

        try deps.append(Dependency{
            .url = url,
            .module = module,
            .parts = parts.items,
        });
    }

    lua.lua_pop(vm, 1);

    return deps.items;
}

const Dir = std.fs.Dir;
const OpenErr = std.fs.Dir.OpenError;
const File = std.fs.File;

pub fn getGlobalInfoDirectory(allocator: Allocator) !Dir {
    const OsTag = std.Target.Os.Tag;
    var target = std.zig.system.NativeTargetInfo.detect(std.zig.CrossTarget{}) catch std.debug.panic("I don't know on what kind of system I am running and I am scared\n", .{});
    switch (target.target.os.tag) {
        OsTag.linux => {
            const homepath = if (std.os.getenv("HOME")) |home| home else return OpenErr.NotDir;
            const folderpath = try std.fs.path.join(allocator, .{ homepath, "heart_tool" });
            defer allocator.free(folderpath);

            // I know there's better ways but I just don't care. If it works it works
            if (std.fs.openDirAbsolute(folderpath, Dir.OpenDirOptions{})) |f| {
                defer f.close();
            } else |err| {
                switch (err) {
                    OpenErr.FileNotFound => {
                        try std.fs.makeDirAbsolute(folderpath);
                    },
                    else => return err,
                }
            }

            const dir = try std.fs.openDirAbsolute(folderpath, Dir.OpenDirOptions{});
            return dir;
        },
        // unsupported platform so shit
        else => std.debug.panic("Your running this on an unsupported platform. I don't know where to find what I need\n", .{}),
    }
}

pub fn main() !void {
    const vm = lua.luaL_newstate().?;
    defer lua.lua_close(vm);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    defer _ = gpa.detectLeaks();

    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    lua.luaL_openlibs(vm);

    if (lua.luaL_loadfilex(vm, "build.lua", "t") != 0) {
        std.debug.print("Unable to load build.lua file. Are you sure its there?\n", .{});
        std.process.exit(1);
    }

    lua.lua_callk(vm, 0, 1, 0, null);
    var deps = try getDependencies(vm, arena_allocator);

    for (deps) |dep| {
        std.debug.print("URL: {s} | Module: {s}\n", .{ dep.url, dep.module });
    }
}
