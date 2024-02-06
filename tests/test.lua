test("A equals B")
ensure(5):is(5)

test("Function calls are good")

local function f(a, b)
    return a + b
end

ensure(f):calledWith(10, 20):succeedsAndValue():equals(30)

test("Deep equality makes sense")
ensure({name = "hello"}):notEqualRecursivelyTo({name = "hello", notInA = true})

ensure({1, 2, 3}):equalsRecursively({1, 2, 3})
