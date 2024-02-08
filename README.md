# Heart

A **build tool** for Love2D.

# Status

Under development.

# Features

You can configure your build options with build.lua file, which must return a table.

## heart fetch

It will look at your build's `dependencies`. The dependencies should be tables with a string that is their git URL, and optionally a `module` field
which is a Lua require path for the folder it should be in.

It will locally clone them or, if they exist, pull. It also fetches the dependencies of your dependencies.

## heart test

It runs `tests/test.lua` with a test environment ready to go.

Here's an example test:
```lua
test("5 is not equals to 3")
ensure(5):isnt(3)
```

## heart bundle

It will look at the files and folders `require`d by your `main.lua` and `conf.lua`, recursively, and it will bundle them together into a zip file.
The output file is `Game.love`.
