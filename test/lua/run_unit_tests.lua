local suites = {
    dofile("test/lua/test_modprofiler.lua"),
    dofile("test/lua/test_modprofiler_ui.lua"),
}

local ok = true
for _, suite in ipairs(suites) do
    if not suite.run() then
        ok = false
    end
end

if ok then
    os.exit(0)
end
os.exit(1)
