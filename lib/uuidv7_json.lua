-- Minimal JSON encoder for uuidv7 (zero-dependency).
--
-- Handles exactly the value types this project emits: nil, boolean, number,
-- string, int64/uint64 cdata, and array/object tables. Object keys are emitted
-- in sorted order for deterministic, testable output.
--
-- Strings are escaped so that ARBITRARY bytes (e.g. logged client input) always
-- produce valid, single-line JSON. That guarantee is what makes the JSONL log
-- injection-proof: a client cannot smuggle a newline + forged object into a log
-- line, because every control byte and every byte >= 0x7f becomes \uXXXX.

local M = {}

local function esc_str(s)
	s = tostring(s)
	local out = {}
	for i = 1, #s do
		local b = s:byte(i)
		if b == 34 then out[#out + 1] = '\\"'          -- "
		elseif b == 92 then out[#out + 1] = '\\\\'      -- backslash
		elseif b == 8 then out[#out + 1] = '\\b'
		elseif b == 9 then out[#out + 1] = '\\t'
		elseif b == 10 then out[#out + 1] = '\\n'
		elseif b == 12 then out[#out + 1] = '\\f'
		elseif b == 13 then out[#out + 1] = '\\r'
		elseif b < 0x20 or b >= 0x7f then
			out[#out + 1] = string.format('\\u%04x', b)
		else
			out[#out + 1] = string.char(b)
		end
	end
	return '"' .. table.concat(out) .. '"'
end

local function is_array(t)
	local n = 0
	for k in pairs(t) do
		if type(k) ~= "number" then return false end
		n = n + 1
	end
	if n == 0 then return false end          -- empty table => object {}
	for i = 1, n do if t[i] == nil then return false end end
	return true, n
end

local function enc(v)
	local tv = type(v)
	if v == nil then
		return "null"
	elseif tv == "boolean" then
		return v and "true" or "false"
	elseif tv == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		if math.floor(v) == v and math.abs(v) < 1e15 then
			return string.format("%d", v)
		end
		return string.format("%.14g", v)
	elseif tv == "string" then
		return esc_str(v)
	elseif tv == "cdata" then
		return (tostring(v):gsub("[uUlL]+$", ""))   -- int64/uint64 -> bare decimal
	elseif tv == "table" then
		local arr, n = is_array(v)
		if arr then
			local parts = {}
			for i = 1, n do parts[i] = enc(v[i]) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		local keys = {}
		for k in pairs(v) do keys[#keys + 1] = k end
		table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
		local parts = {}
		for _, k in ipairs(keys) do
			parts[#parts + 1] = esc_str(tostring(k)) .. ":" .. enc(v[k])
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	error("uuidv7_json: cannot encode type " .. tv)
end

M.encode = enc
return M
