-- FLASHLIGHT — the clamp-on helmet torch (items.lua "flashlight").
--
-- Carried in the suit pack, it rides strapped to the helmet's side
-- (prefabs/ItemFlashlight, parented to the AstroModel's "Helmet" node) and L
-- switches it on and off, on foot, whatever is in the hands. The beam is one
-- spot light (a point light with a cone, aimed down its node's -Z) placed
-- every lateUpdate at the torch's lens as it is drawn this frame (rule 2,
-- docs/positions-and-frames.md), looking where the crew looks: the camera's
-- way while that is within `turn` of the helmet's own forward (the head
-- turns to look), the helmet's forward past it. The direction is eased
-- (rule 7: a direction, so no planet lag) and snaps when first lit.
--
-- A real torch, not a floodlight: a warm-white LED, a 40° cone with a soft
-- edge, about 30 m of useful throw, local shadows. Its
-- battery is the item's FILL (inventory's per-piece levels, shown as %): it
-- drains while lit (`hours` of light from full), the beam browns out and
-- flickers under 10 %, and it goes dark at 0. It charges aboard a craft or
-- near the base (`recharge` %/s), as the rifle's cell does.
--
-- Rides the ItemsLib node. Published for probes: `on`, `lit` (the light's
-- intensity this frame), `level` (0..100), `lensX/Y/Z`, `dirX/Y/Z`;
-- `setOn(bool)`, `toggle()`; `sim` = { pressed = true } presses L once.

defaults = {
  --@range 10 60 --@units deg
  cone = 40.0,
  --@range 0 1
  softness = 0.7,
  --@range 5 80 --@units m
  range = 30.0,
  --@range 0 8
  intensity = 2.2,
  --- Hours of light from a full battery.
  --@range 0.5 24
  hours = 4.0,
  --- % a second it charges aboard or near the base.
  --@range 0 10
  recharge = 0.25,
  --@range 10 200 --@units m
  home_r = 90.0,
  --- How far (deg) the head turns from the helmet's forward to follow the view.
  --@range 0 120
  turn = 95.0,
  --@range 0 1
  sound = 1.0,
}

on = false
lit = 0
level = nil
lensX, lensY, lensZ = nil, nil, nil
spot = nil   -- (probes) the light's cone as the engine has it, degrees
dirX, dirY, dirZ = nil, nil, nil
sim = nil

local ID = "flashlight"
-- Where the torch is strapped, in the Helmet node's frame (its centre; +Z
-- ahead, +Y up): on the side shell above the lamp housing, the clamp inboard.
local MOUNT = { 0.226, 0.062, 0.012 }
-- The lens in the torch model's own frame (tools/gen_items.py prints it).
local LENS = { 0.0038, 0.0, 0.0635 }
local COLOR = { 1.0, 0.92, 0.78 }

local R = { model = nil, helmet = nil, am = nil, light = nil, making = false, spawning = false,
            dir = nil, aimed = false, save_t = 0, flick = 1, flick_t = 0, lens_lit = nil }

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function P(k) return (params and params[k]) or defaults[k] end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function astro() return find and find("Astronaut") or nil end
local function kids(n)
  if not (n and n.valid ~= false and n.children) then return {} end
  local ok, c = pcall(n.children, n)
  return ok and c or {}
end

local function pack()
  local C = ref("crew")
  local id = C and C.activeId and C.activeId()
  return id and ("crew:" .. id) or "astro"
end
local function carried()
  local inv = ref("inventory")
  if not (inv and inv.itemCount) then return false end
  local ok, n = pcall(inv.itemCount, pack(), ID)
  return ok and (n or 0) > 0
end

-- the battery: the fullest torch in the pack is the one on the helmet
local function battery()
  local inv = ref("inventory")
  if not (inv and inv.fills) then return nil end
  local list = inv.fills(pack(), ID)
  local best
  for _, f in ipairs(list) do if not best or f > best then best = f end end
  return best, list
end
local function battery_add(amount)
  local inv = ref("inventory")
  if not (inv and inv.fills and save) then return end
  local cid = pack()
  local list = inv.fills(cid, ID)
  if #list == 0 then return end
  if amount < 0 then
    -- drawn from the fullest (the one on the helmet)
    local bi = 1
    for i, f in ipairs(list) do if f > list[bi] then bi = i end end
    list[bi] = math.max(0, list[bi] + amount)
  else
    -- every torch in the pack charges
    local any = false
    for i = 1, #list do if list[i] < 100 then any = true end; list[i] = math.min(100, list[i] + amount) end
    if not any then return end
  end
  local t = save.get("inv.fill." .. cid)
  t = type(t) == "table" and t or {}
  t[ID] = list
  save.set("inv.fill." .. cid, t)
end
local function charging()
  local C = ref("crew")
  if C and C.avatarCraft and C.avatarCraft() then return true end
  local a = astro()
  local fo = ref("flight_ops")
  if a and fo and fo.crewHome then
    local ok, hx, hy, hz = pcall(fo.crewHome)
    if ok and hx and len(a.x - hx, a.y - hy, a.z - hz) < P("home_r") then return true end
  end
  return false
end

local function say(s)
  local fx = ref("sfx")
  if fx and fx.caption then pcall(fx.caption, s) elseif caption then pcall(caption, s) end
end
local function click(state)
  if (P("sound") or 1) <= 0 or not (audio and audio.play) then return end
  pcall(audio.play, state and "audio/foley/toggle_on.ogg" or "audio/foley/toggle_off.ogg",
    { track = "SFX", volume = 0.28 * P("sound") })
end

local function persist() if save and save.set then save.set("crew.torch", on and 1 or 0) end end

function setOn(want)
  want = want and true or false
  if want and not carried() then return false, "no flashlight in the pack" end
  if want then
    local b = battery()
    if b and b <= 0.05 then say("the flashlight's battery is flat (it charges aboard or at the base)") return false, "flat" end
  end
  if want ~= on then on = want; click(on); persist() end
  return true
end
function toggle() return setOn(not on) end

-- ── the nodes ───────────────────────────────────────────────────────────────
local function helmet_node()
  if R.helmet and R.helmet.valid then return R.helmet end
  R.helmet = nil
  local a = astro()
  if not a then return nil end
  if not (R.am and R.am.valid) then
    R.am = nil
    for _, c in ipairs(kids(a)) do if c.name == "AstroModel" then R.am = c end end
  end
  for _, c in ipairs(kids(R.am)) do if c.name == "Helmet" then R.helmet = c end end
  return R.helmet
end

local function model_node(h)
  if R.model and R.model.valid then return R.model end
  if R.spawning or not (spawn and h) then return nil end
  R.spawning = true
  local ok = pcall(spawn, "ItemFlashlight", h.worldPos or vec3(h.x, h.y, h.z), function(n)
    R.spawning = false
    R.model = n
    n.castShadow = true
    n:setParent(h, { keepWorld = false })
    n.x, n.y, n.z = MOUNT[1], MOUNT[2], MOUNT[3]
    n:setAngles(0, 0, 0)
    n.visible = false
  end)
  if not ok then R.spawning = false end
  return nil
end

local function light_node()
  if R.light and R.light.valid then return R.light end
  if R.making or not createNode then return nil end
  R.making = true
  createNode("Flashlight Beam", nil, function(n)
    R.making = false
    R.light = n
    pcall(n.setPointLight, n, { color = COLOR, intensity = 0, range = P("range") })
    R.aimed = false   -- the cone is set once the light component exists (set_light)
  end)
  return nil
end

local function lens_glow(m, k)
  if R.lens_lit == k or not (m and m.material) then return end
  R.lens_lit = k
  pcall(function()
    local mt = m:material("Lens")
    mt.color = { 0.62, 0.64, 0.62 }
    mt.texture = "textures/base/lens.png"
    mt.roughness = 0.25
    mt.metallic = 0.0
    mt.emissive = { COLOR[1], COLOR[2], COLOR[3] }
    mt.emissiveStrength = 4.0 * k
  end)
end

local function set_light(I)
  local n = R.light
  if not (n and n.valid) then return end
  local l = n.getcomponent and n:getcomponent("PointLight")
  if not l then lit = 0 return end
  -- a light made this frame has no component until the engine applies it, so
  -- the cone (spotAngle < 180 is a spot down -Z), its edge and its shadows go
  -- on here, the first frame the component answers
  if not R.aimed or (l.spotAngle or 180) >= 179 then
    pcall(function() l.spotAngle = P("cone") end)
    pcall(function() l.spotSoftness = P("softness") end)
    pcall(function() l.shadows = 1 end)
    pcall(function() l.range = P("range") end)
    R.aimed = true
  end
  spot = l.spotAngle
  if math.abs((l.intensity or 0) - I) > 0.005 then l.intensity = I end
  lit = I
end

-- ── input ───────────────────────────────────────────────────────────────────
local function free_hands()
  local pw = ref("planet_walker")
  if not (pw and pw.onFoot == true) then return false end
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.inputOwner == "builder") then return false end
  local pm = ref("pause_menu")
  if pm and pm.open then return false end
  for _, k in ipairs({ "facility_menu", "ops_board", "orbit_map", "context_menu" }) do
    local s = ref(k)
    if s and s.isOpen and s.isOpen() then return false end
  end
  local ip = ref("inventory_panel")
  if ip and ip.open then return false end
  return true
end

function start()
  on = (save and save.get and (save.get("crew.torch") or 0) ~= 0) or false
  -- the registry's numbers are the card's: the beam follows them
  local I = ref("items")
  local d = I and I.def and I.def(ID)
  if d and d.lamp then
    defaults.cone = d.lamp.cone or defaults.cone
    defaults.range = d.lamp.range or defaults.range
    defaults.hours = d.lamp.hours or defaults.hours
  end
end

function update(node, dt)
  local press = false
  if sim and sim.pressed then sim.pressed = nil; press = true end
  if not press and input and input.pressed and input.pressed("l") and free_hands() then press = true end
  if press then
    local ok, why = toggle()
    if not ok and why == "no flashlight in the pack" then say("no flashlight in the pack (the depot sells one)") end
  end
  -- the battery, once a second
  R.save_t = R.save_t + (dt or 0)
  if R.save_t >= 1.0 then
    local step = R.save_t
    R.save_t = 0
    if carried() then
      if on and lit > 0 then battery_add(-step * 100 / (P("hours") * 3600)) end
      if charging() then battery_add(step * P("recharge")) end
      local b = battery()
      if on and b and b <= 0.05 then on = false; persist(); click(false); say("the flashlight's battery is flat") end
    end
  end
  level = (battery())
end

function lateUpdate(node, dt)
  local have = carried()
  if on and not have then on = false; persist() end
  local h = helmet_node()
  local m = (have and h) and model_node(h) or (R.model and R.model.valid and R.model or nil)
  local pw = ref("planet_walker")
  local afoot = pw and pw.onFoot == true
  if m then
    local show = have and afoot and true or false
    if m.visible ~= show then m.visible = show end
  end
  local want = on and have and afoot and m ~= nil
  local ln = (want or (R.light and R.light.valid)) and light_node() or nil
  if not want then
    if ln then set_light(0) end
    if m then lens_glow(m, 0) end
    R.dir = nil
    lit = 0
    return
  end
  if not ln then return end
  -- the lens and the helmet's forward, as drawn this frame
  local o = m:toWorld(vec3(LENS[1], LENS[2], LENS[3]))
  local f0 = m:toWorld(vec3(LENS[1], LENS[2], LENS[3] + 1)) - o
  local up = m:toWorld(vec3(LENS[1], LENS[2] + 1, LENS[3])) - o
  f0 = f0:normalized(); up = up:normalized()
  -- where the crew looks: the camera's forward, within `turn` of the helmet's
  local dir = f0
  local pc = ref("planet_camera")
  local cn = pc and pc.node
  if cn and cn.valid ~= false and cn.worldForward then
    local cf = cn:worldForward()
    if cf and cf:length() > 0.5 then
      cf = cf:normalized()
      if cf:dot(f0) >= math.cos(math.rad(P("turn"))) then dir = cf end
    end
  end
  if R.dir then
    local k = 1 - math.exp(-12 * (dt or 0.016))
    local d = R.dir + (dir - R.dir) * k
    if d:length() > 1e-6 then R.dir = d:normalized() end
  else
    R.dir = dir
  end
  dir = R.dir
  local px, py, pz = o.x + dir.x * 0.04, o.y + dir.y * 0.04, o.z + dir.z * 0.04
  ln.x, ln.y, ln.z = px, py, pz
  local u = up - dir * up:dot(dir)
  if u:length() < 1e-3 then u = vec3(0, 1, 0) end
  -- setUp: +Y along u, and -Z (the spot's axis) toward dir
  ln:setUp(u:normalized(), dir)
  lensX, lensY, lensZ = px, py, pz
  dirX, dirY, dirZ = dir.x, dir.y, dir.z
  -- the battery's state in the beam: a brown-out and a flicker under 10 %
  local b = level or 100
  local k = 1.0
  if b < 10 then
    k = 0.35 + 0.65 * (b / 10)
    R.flick_t = R.flick_t - (dt or 0.016)
    if R.flick_t <= 0 then
      R.flick = (math.random() < 0.25) and (0.15 + 0.5 * math.random()) or 1.0
      R.flick_t = 0.04 + 0.25 * math.random()
    end
    k = k * R.flick
  end
  set_light(P("intensity") * k)
  lens_glow(m, math.floor(k * 10 + 0.5) / 10)
end
