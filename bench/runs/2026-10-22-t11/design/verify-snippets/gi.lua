local ok, info = pcall(debug.getinfo, 1, "S")
print("via pcall:", ok, info and info.source)
local info2 = debug.getinfo(1, "S")
print("direct:", info2 and info2.source)
local function scriptdir()
  if not debug or type(debug.getinfo) ~= "function" then return nil end
  local ok3, inf = pcall(debug.getinfo, 1, "S")
  if not ok3 or type(inf) ~= "table" or type(inf.source) ~= "string" then return nil end
  local src = inf.source
  if src:sub(1, 1) ~= "@" and src:sub(1, 1) ~= "=" then return nil end
  return src:sub(2):match("^(.*)[/\\][^/\\]*$")
end
print("scriptdir():", scriptdir())
