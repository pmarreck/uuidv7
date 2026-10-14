-- Stub daemon for client tests: listens on a Unix socket and answers every request
-- with one fixed reply, appending each request line to a record file. Prints
-- "STUB-LISTENING" once ready and exits after a request line of exactly "STOP".
-- Usage: luajit uuidv7_stub_daemon.lua <socket> <reply> <record-file>
local self_dir = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]+$") or "."
package.path = self_dir .. "/../lib/?.lua;" .. package.path
local ffi = require("ffi")
local net = require("uuidv7_net")

local path, reply, record = arg[1], arg[2], arg[3]
reply = reply:gsub("\\n", "\n")
local lfd = assert(net.listen(path))
io.write("STUB-LISTENING\n"); io.flush()

local buf = ffi.new("char[4096]")
while true do
	net.poll({ lfd }, -1)
	local cfd = net.accept(lfd)
	if cfd then
		local got = {}
		while true do
			local n = net.recv(cfd, buf, 4096)
			if n <= 0 then break end
			got[#got + 1] = ffi.string(buf, n)
		end
		local line = table.concat(got):gsub("\n$", "")
		if line == "STOP" then net.close(cfd); break end
		local f = assert(io.open(record, "ab")); f:write(line, "\n"); f:close()
		net.send(cfd, ffi.cast("const char*", reply), #reply)
		net.close(cfd)
	end
end
net.close(lfd)
os.remove(path)
