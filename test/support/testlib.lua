local Test = { cases = {} }

local function fail(message)
    error(message, 2)
end

function Test.case(name, fn)
    Test.cases[#Test.cases + 1] = { name = name, fn = fn }
end

function Test.eq(actual, expected, message)
    if actual ~= expected then
        fail(string.format("%sexpected <%s> but got <%s>", message and (message .. ": ") or "", tostring(expected), tostring(actual)))
    end
end

function Test.near(actual, expected, tolerance, message)
    tolerance = tolerance or 0.0001
    if math.abs(actual - expected) > tolerance then
        fail(string.format("%sexpected %.6f +/- %.6f but got %.6f", message and (message .. ": ") or "", expected, tolerance, actual))
    end
end

function Test.truthy(value, message)
    if not value then
        fail(message or "expected truthy value")
    end
end

function Test.run()
    local passed = 0
    local failed = 0

    for index, case in ipairs(Test.cases) do
        io.write(string.format("[%02d/%02d] %s ... ", index, #Test.cases, case.name))
        local ok, err = xpcall(case.fn, debug.traceback)
        if ok then
            passed = passed + 1
            io.write("ok\n")
        else
            failed = failed + 1
            io.write("FAIL\n")
            io.write(err .. "\n")
        end
    end

    io.write(string.format("\nLua unit tests: %d passed, %d failed\n", passed, failed))
    return failed == 0
end

return Test
