-- Run POSIX shell command lines from the LuaJIT test suites on every OS.
-- io.popen and os.execute use /bin/sh on POSIX but cmd.exe on Windows; there each
-- line is written to a script that Git for Windows' bash runs, so the suites keep
-- one command syntax. execute() returns a boolean on every LuaJIT build (plain
-- os.execute returns the exit status, which is truthy even when nonzero).
local M = {}
local is_windows = jit.os == "Windows"
local scripts = {}

function M.cmd(line)
	if not is_windows then return line end
	local dir = (os.getenv("TMPDIR") or os.getenv("TEMP") or "."):gsub("[/\\]+$", "")
	local path = string.format("%s/uuidv7-testsh-%d-%d.sh", dir, os.time(), #scripts + 1)
	local f = assert(io.open(path, "wb"))
	f:write(line, "\n")
	f:close()
	scripts[#scripts + 1] = path
	return 'bash "' .. path .. '"'
end

function M.popen(line, mode) return io.popen(M.cmd(line), mode) end

function M.execute(line)
	local r = os.execute(M.cmd(line))
	return r == true or r == 0
end

-- Force-stop a process by the PID the daemon reports (a native Windows PID there).
-- hard sends SIGKILL, so no shutdown code runs (taskkill //F is always hard).
function M.kill(pid, hard)
	if is_windows then return M.execute("taskkill //F //PID " .. pid .. " >/dev/null 2>&1") end
	return M.execute("kill " .. (hard and "-9 " or "") .. pid .. " 2>/dev/null")
end

function M.cleanup()
	for _, p in ipairs(scripts) do os.remove(p) end
	scripts = {}
end

return M
