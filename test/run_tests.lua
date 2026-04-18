local python = os.getenv("PYTHON") or "python"
local command = string.format('%s "%s"', python, "test/run_tests.py")
local ok, why, code = os.execute(command)

if type(ok) == "number" then
    os.exit(ok)
end
if ok == true then
    os.exit(0)
end
if type(code) == "number" then
    os.exit(code)
end
os.exit(1)
