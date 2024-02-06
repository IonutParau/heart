const std = @import("std");
const lua = @cImport({
    @cInclude("lua/lua.h");
    @cInclude("lua/lualib.h");
    @cInclude("lua/lauxlib.h");
});
const clap = @import("zigclap");

const Allocator = std.mem.Allocator;

const Dependency = struct {
    url: []const u8,
    module: []const u8,
};

fn getDependencies(vm: *lua.lua_State, allocator: Allocator) ![]const Dependency {
    var deps = std.ArrayList(Dependency).init(allocator);
    var i: usize = 0;

    if (!lua.lua_istable(vm, -1)) {
        return deps.items;
    }

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
            var modulePref: []const u8 = "packages.";
            var cstr = try allocator.allocSentinel(u8, str.len + modulePref.len, 0);
            cstr.len = modulePref.len;
            @memcpy(cstr, modulePref);
            cstr.ptr += modulePref.len;
            cstr.len = str.len;
            @memcpy(cstr, str);
            cstr.len += modulePref.len;
            cstr.ptr -= modulePref.len;
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

        try deps.append(Dependency{
            .url = url,
            .module = module,
        });
    }

    lua.lua_pop(vm, 1);

    return deps.items;
}

const Dir = std.fs.Dir;
const OpenErr = std.fs.Dir.OpenError;
const File = std.fs.File;

fn localPath(lua_path: []const u8, allocator: Allocator) ![]const u8 {
    var l = std.ArrayList([]const u8).init(allocator);
    errdefer l.deinit();
    var parts = std.mem.split(u8, lua_path, ".");
    while (parts.next()) |part| {
        try l.append(part);
    }
    return std.mem.join(allocator, std.fs.path.sep_str, l.items);
}

fn gitUrl(url: []const u8, allocator: Allocator) ![]const u8 {
    // Is already a proper URL?
    if (std.mem.count(u8, url, "://") > 0) {
        // We alloc a copy cuz caller probably expects us to free
        var buf = try allocator.alloc(u8, url.len);
        @memcpy(buf, url);
        return buf;
    }

    // Does it contain a .? Then it probably has a domain, so we just prepend https:// (all major git repos support cloning via HTTPS)
    if (std.mem.count(u8, url, ".") > 0) {
        var buf = try std.mem.join(allocator, "", &[_][]const u8{ "https://", url });
        return buf;
    }

    // Fallback: Just add https://github.com/ in front, most repos are on github
    return try std.mem.join(allocator, "", &[_][]const u8{ "https://github.com/", url });
}

pub fn fetchSubdependencies(vm: *lua.lua_State, stdout: anytype, allocator: Allocator, dir_path: []const u8) !void {
    var buildFilePath = try std.fs.path.join(allocator, &[_][]const u8{ dir_path, "build.lua" });
    defer allocator.free(buildFilePath);

    var buildFilePathC = try allocator.allocSentinel(u8, buildFilePath.len, 0);
    defer allocator.free(buildFilePathC);

    @memcpy(buildFilePathC, buildFilePath);

    if (std.fs.cwd().openFile(buildFilePath, std.fs.File.OpenFlags{})) |file| {
        file.close();
    } else |_| {
        return;
    }

    if (lua.luaL_loadfilex(vm, buildFilePathC, "t") != 0) {
        std.debug.print("Unable to load {s} file. Are you sure its there?\n", .{buildFilePath});
        std.process.exit(1);
    }

    lua.lua_callk(vm, 0, 1, 0, null);
    _ = lua.lua_getfield(vm, -1, "dependencies");
    var deps = try getDependencies(vm, allocator);
    _ = lua.lua_pop(vm, 1);

    for (deps) |dep| {
        try fetchDependency(vm, dep, stdout, allocator);
    }
}

const FetchDependencyError = Allocator.Error || std.fs.File.WriteError || std.process.Child.SpawnError;

pub fn fetchDependency(vm: *lua.lua_State, dependency: Dependency, stdout: anytype, allocator: Allocator) FetchDependencyError!void {
    try stdout.print("Downloading {s} for {s}\n", .{ dependency.url, dependency.module });

    // Resolve local path for cloning
    var local_path = try localPath(dependency.module, allocator);
    defer allocator.free(local_path);
    try stdout.print("Putting {s} into {s}\n", .{ dependency.module, local_path });

    defer {
        fetchSubdependencies(vm, stdout, allocator, local_path) catch unreachable;
    }

    if (std.fs.cwd().openDir(local_path, std.fs.Dir.OpenDirOptions{})) |dir| {
        var dirAlias = dir;
        defer dirAlias.close();
        try stdout.print("Directory {s} already exists! Pulling...\n", .{local_path});
        var process = std.process.Child.init(&[_][]const u8{ "git", "pull" }, allocator);
        process.cwd_dir = dirAlias;
        var processTerm = try process.spawnAndWait();
        const Status = std.process.Child.Term;
        switch (processTerm) {
            Status.Exited => |u| {
                if (u != 0) {
                    std.debug.panic("Pulling from {s} FAILED!\n", .{local_path});
                }
            },
            else => {},
        }
        return;
    } else |_| {}

    // Resolve URL for cloning
    var url = try gitUrl(dependency.url, allocator);
    defer allocator.free(url);
    try stdout.print("Cloning from {s}\n", .{url});

    var process = std.process.Child.init(&[_][]const u8{ "git", "clone", url, local_path }, allocator);
    var processTerm = try process.spawnAndWait();
    const Status = std.process.Child.Term;
    switch (processTerm) {
        Status.Exited => |u| {
            if (u != 0) {
                std.debug.panic("Cloning {s} into {s} FAILED!\n", .{ url, local_path });
            }
        },
        else => {},
    }
}

pub fn main() !void {
    const vm = lua.luaL_newstate().?;
    _ = lua.luaL_openlibs(vm);
    defer lua.lua_close(vm);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    defer _ = gpa.detectLeaks();

    const params = comptime clap.parseParamsComptime(
        \\-h, --help Display this help and exit.
        \\<action> An action to perform. Can be fetch to fetch dependencies, test to run tests, purge to purge unused dependencies or bundle to bundle to a
        \\distributable file format.
    );
    var diag = clap.Diagnostic{};
    const Action = enum { fetch, @"test", bundle };
    const parsers = comptime .{
        .action = clap.parsers.enumeration(Action),
    };
    var res = clap.parse(clap.Help, &params, parsers, .{
        .diagnostic = &diag,
        .allocator = gpa.allocator(),
    }) catch |err| {
        diag.report(std.io.getStdErr().writer(), err) catch unreachable;
        return err;
    };
    defer res.deinit();

    const allocator = gpa.allocator();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    if (lua.luaL_loadfilex(vm, "build.lua", "t") != 0) {
        std.debug.print("Unable to load build.lua file. Are you sure its there?\n", .{});
        std.process.exit(1);
    }

    lua.lua_callk(vm, 0, 1, 0, null);
    _ = lua.lua_getfield(vm, -1, "dependencies");
    var deps = try getDependencies(vm, arena_allocator);
    _ = lua.lua_pop(vm, 1);

    const stdout = std.io.getStdOut().writer();

    if (res.positionals.len == 0) {
        try clap.help(stdout, clap.Help, &params, .{});
        return;
    }

    if (res.positionals[0] == Action.fetch) {
        for (deps) |dep| {
            try fetchDependency(vm, dep, stdout, arena_allocator);
        }
    }

    if (res.positionals[0] == Action.@"test") {
        const testEnv = @embedFile("testenv.lua");
        _ = lua.luaL_loadstring(vm, testEnv);
        lua.lua_callk(vm, 0, 0, 0, null);
        _ = lua.luaL_loadstring(vm, "require('tests.test') sayTestSucceeded()");
        lua.lua_callk(vm, 0, 0, 0, null);
    }

    if (res.positionals[0] == Action.bundle) {
        const bundling = @import("bundling.zig");
        var requires = try bundling.findRequires(vm, "require('src.main') require('test') require('all.these.tests')", arena_allocator);
        defer arena_allocator.free(requires);
        defer {
            for (requires) |req| {
                arena_allocator.free(req);
            }
        }

        for (requires) |req| {
            try stdout.print("{s}\n", .{req});
        }
    }
}
