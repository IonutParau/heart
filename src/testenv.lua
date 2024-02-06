-- Test Environment.
-- Bundled with executable.

local currentTest
local currentTestFailed = false

function test(name)
    if currentTest then
        print("Test succeeded")
    end
    currentTest = name
    currentTestFailed = false
    print("Testing: " .. name .. "...")
end

function sayTestSucceeded()
    if not currentTestFailed then
        print("Test succeeded")
    end
end

function fail(msg)
    if currentTestFailed then return end
    currentTestFailed = true

    print("Test Failed: " .. currentTest)
    print("Reason: " .. msg)
end

local EnsuringContext = {}

function EnsuringContext:equals(b)
    if self.val ~= b then
        fail("a did not equal b")
    end
end

function EnsuringContext:is(b)
    self:equals(b)
end

function EnsuringContext:notEqualTo(b)
    if self.val == b then
        fail("a did equal b")
    end
end

function EnsuringContext:isnt(b)
    self:notEqualTo(b)
end

local deepcopy
deepcopy = function(a, b)
    if type(a) ~= type(b) then return false end

    if type(a) ~= "table" then
        if a ~= b then return false end
        if b ~= a then return false end
        return true
    end

    for k, v in pairs(a) do
        if not deepcopy(v, b[k]) then
            return false
        end
    end
    for k, v in pairs(b) do
        if not deepcopy(v, a[k]) then
            return false
        end
    end

    return true
end

function EnsuringContext:equalsRecursively(b)
    if not deepcopy(self.val, b) then
        fail("a does not recursively equal b")
    end
end

function EnsuringContext:notEqualRecursivelyTo(b)
    if deepcopy(self.val, b) then
        fail("a does recursively equal b")
    end
end

function EnsuringContext:stringifiesTo(s)
    if not tostring(self.val) ~= s then
        fail("a does not stringify to " .. s)
    end
end

function EnsuringContext:value()
    return self.val
end

local FunctionContext = {}

function FunctionContext:crashes()
    local success = pcall(self.f, table.unpack(self.args))
    if success then
        fail("call succeeded")
    end
end

function FunctionContext:succeeds()
    local success = pcall(self.f, table.unpack(self.args))
    if not success then
        fail("call failed")
    end
end

function FunctionContext:succeedsAndValue()
    local success, v = pcall(self.f, table.unpack(self.args))
    if not success then
        fail("call failed")
        return ensure(nil)
    end
    return ensure(v)
end

function EnsuringContext:calledWith(...)
    return setmetatable({
        f = self.val,
        args = {...},
    }, {__index = FunctionContext})
end

function ensure(a)
    return setmetatable({val = a}, {__index = EnsuringContext})
end
