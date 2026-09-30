-- SMOKE LINT: no script may export a name the engine has already taken.
--
-- A `findScript` handle is a PROXY, not the script's table. Its `__index` answers
-- three keys itself, before it ever looks inside the script:
--
--     node    → a node handle for the script's own node
--     kind    → the script's name, as a string
--     valid   → whether the script is still loaded
--
-- A script that exports one of those can call it from inside itself and from
-- nowhere else. Every caller gets the ENGINE's value back and dies on the call:
--
--     x.kind(id)   →  attempt to call field 'kind' (a string value)
--
-- THERE WERE FOUR. `name` was the fourth, and it was the one every game wants:
-- `materials.name("iron")` → `"Iron Ore"` is the obvious thing to write, and it
-- broke the mining laser's readout, the pickup line, the depot's stock list and
-- the research panel — everything that puts a material's name on screen, each
-- only at the moment it had something to show. Filed as floptle/0085 and fixed
-- in v0.33.0: your `name` wins now, and the remaining three are reported when
-- the script loads instead of surfacing later in somebody else'"'"'s file.
--
-- This file stays because the engine'"'"'s check is a load-time report and this is a
-- build-time refusal, and because the CALL-SITE half below has no engine
-- equivalent — nothing warns you that `x.kind(...)` was never going to work.
--
-- WHY NO OTHER TEST CAUGHT THE ORIGINAL: every harness stubs cross-script
-- singletons as plain Lua tables, where `name` is just a key and resolves to the
-- function. The proxy is the whole difference, and the stubs do not model it.
-- This file checks the property directly instead, which is cheaper than teaching
-- a dozen harnesses to be proxies and cannot rot the same way.
--
--   luajit solar/tests/smoke_api_reserved.lua

local RESERVED = { node = true, kind = true, valid = true }

local checks, failures = 0, {}
local function ok(cond, msg)
  checks = checks + 1
  if not cond then failures[#failures + 1] = msg end
end

-- Every script the game ships. Read as TEXT rather than loaded: loading runs
-- top-level code that expects a live engine, and what is being asked here is a
-- question about the source.
local scripts = {}
local p = io.popen("ls solar/scripts/*.lua 2>/dev/null")
if p then
  for line in p:lines() do scripts[#scripts + 1] = line end
  p:close()
end
ok(#scripts > 10, "found the game's scripts to lint — got " .. #scripts)

local offenders = 0
for _, path in ipairs(scripts) do
  local fh = assert(io.open(path, "r"))
  local src = fh:read("*a")
  fh:close()
  local short = path:match("([^/]+)%.lua$") or path
  -- A global function declaration at the top level: `function name(...)`.
  -- Locals are fine — they are not reachable through a handle at all, which is
  -- the point.
  for decl in src:gmatch("\n%s*function%s+([%w_]+)%s*%(") do
    if RESERVED[decl] then
      offenders = offenders + 1
      failures[#failures + 1] = string.format(
        "%s exports `%s`, which a script handle answers itself — every caller "
        .. "outside this file gets the engine's value, not the function",
        short, decl)
    end
  end
  -- The same trap for a plain global assignment (`name = ...` at top level),
  -- which is how a script publishes a value rather than a function.
  for decl in src:gmatch("\n([%w_]+)%s*=%s*[^=]") do
    if RESERVED[decl] then
      offenders = offenders + 1
      failures[#failures + 1] = string.format(
        "%s publishes `%s`, which a script handle answers itself", short, decl)
    end
  end
end
checks = checks + 1
if offenders > 0 then
  -- Counted as one failed check; the per-script lines above say which.
else
  ok(true, nil)
end

-- And the other half: nothing may CALL a reserved key on a cross-script handle.
-- `mats.name(...)` is the exact shape that broke, and it is greppable.
local HANDLES = { "mats", "inv", "co", "cl", "fg", "mf", "ff", "gm", "pw", "mi",
                  "rs", "ob", "ip", "fm", "bf", "v", "s" }
local call_hits = 0
for _, path in ipairs(scripts) do
  local fh = assert(io.open(path, "r"))
  local src = fh:read("*a")
  fh:close()
  local short = path:match("([^/]+)%.lua$") or path
  for _, h in ipairs(HANDLES) do
    for key in src:gmatch("[^%w_]" .. h .. "%.([%w_]+)%s*%(") do
      -- `valid` is never a call and `node` is a value; `kind` is the one that
      -- still reads as a plausible function call on a handle. (`name` was here
      -- too until v0.33.0 gave it back to the game.)
      if key == "kind" then
        call_hits = call_hits + 1
        failures[#failures + 1] = string.format(
          "%s calls `%s.%s(...)` — that key belongs to the handle, not the script",
          short, h, key)
      end
    end
  end
end
checks = checks + 1
ok(call_hits == 0, nil)

if #failures == 0 then
  print(string.format("RESERVED-NAME LINT OK — %d scripts, nothing shadowed", #scripts))
  os.exit(0)
end
print("RESERVED-NAME LINT FAILURES:")
for _, f in ipairs(failures) do
  if f then print("  \xe2\x9c\x97 " .. f) end
end
os.exit(1)
