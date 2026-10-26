-- SUIT — the crew's EVA suit, and the helmet that comes off.
--
-- The suit (models/astronaut/astronaut_male.glb, tools/gen_suit.py) is one
-- skinned model; its helmet is not part of it. The helmet, its gold visor and
-- its lamps are three plain models the scene hangs on the suit's Back bone
-- (an `attachment` under the AstroModel: "Helmet", and under it "Helmet
-- Visor" and "Helmet Lamps"), so taking the helmet off is hiding a node —
-- and under it is the crew's own head in a comm cap.
--
-- WHEN IT MAY COME OFF. Only in air a person can breathe: on foot, not under
-- water, on a world whose air has oxygen (aero.lua `oxygen`: a living world,
-- and the home world always), thick enough where the crew stands (the air's
-- share at this height, aero.lua `airShare`, at least `thin_air`), and
-- neither too cold nor too hot to stand in bare-headed. Anywhere else
-- `setHelmet(false)` is refused with the reason, in words a player reads.
--
-- WHAT KEEPS IT HONEST. If the crew is bare-headed and the air stops being
-- breathable — they walk up out of it, or step out of a craft on another
-- world — the helmet goes back on at once (a crew does not walk into vacuum
-- with it off), with a caption saying why. Under water bare-headed the crew
-- is holding their breath: planet_walker drains the tank `breath_hold` times
-- faster (`breathMult`). Aboard a craft the cabin is air, so whatever the
-- crew wears there stays as it is.
--
-- The state is in the save ("crew.helmet", "crew.visor", "crew.lamps"), and
-- checked against the air again on the first frame on foot after a load.
--
-- THE API (the context menu, probes):
--
--   local a = findScript("suit")
--   a.helmetOn()               true while the helmet is on
--   a.canRemoveHelmet()        ok, reason — may it come off here, now?
--   a.helmetRefusal(want)      nil if the helmet may go to `want` (true = on)
--                              now, else the reason
--   a.setHelmet(on [, opts])   ok, reason — on/off; opts.instant skips the
--                              hands-to-the-neck-ring animation (a node or
--                              anything else there is ignored); refused
--                              (false, reason) where it may not come off, or
--                              while a change is under way
--   a.toggleHelmet()           ok, reason
--   a.busy                     true while the hands are at the neck ring
--   a.visorDown() / a.setVisor(down)   the gold sun visor (raised = the face
--                              shows through the clear bubble); only with the
--                              helmet on
--   a.lampsOn() / a.setLamps(on)       the helmet lamps' glow
--   a.breathMult()             how much faster the tank drains under water
--                              (planet_walker): 1, or `breath_hold` bare-headed
--   a.lastReason               the last refusal's words, or nil
--
-- Rides the Astronaut node, after tool_belt (its lateUpdate puts the hands on
-- the neck ring over the tool's hold).

defaults = {
  --- Seconds the hands spend going to the neck ring, turning it and coming
  --- back; the helmet comes off (or goes on) at the middle.
  --@range 0.3 3
  anim_secs = 1.2,
  --- How many times faster the air goes under water bare-headed (a held
  --- breath against a full tank).
  --@range 1 10
  breath_hold = 3.0,
  --- The thinnest air (its share of the ground's, at the crew's height) the
  --- helmet may come off in.
  --@range 0 1
  thin_air = 0.55,
  --- Too cold (K) and too hot (K) to stand in bare-headed.
  --@range 150 300
  cold_k = 228,
  --@range 280 400
  hot_k = 330,
}

local P = setmetatable({}, { __index = function(_, k) return (params and params[k]) or defaults[k] end })

-- Published state.
helmet = true
visor = true          -- the gold visor down
lamps = true
busy = false
lastReason = nil
changes = 0           -- helmet on/off changes this session (probes)

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end

local self_node = nil
local model, nodes = nil, {}          -- the AstroModel; Helmet / Visor / Lamps nodes
local loaded = false
local checked_load = false
local anim = { t = 0, want = nil, flipped = false }

local NODE_NAMES = { helmet = "Helmet", visor = "Helmet Visor", lamps = "Helmet Lamps" }

local function kids(n)
  return (n and n.valid ~= false and n.children and n:children()) or {}
end

local function resolve(node)
  if not (model and model.valid) then
    model, nodes = nil, {}
    for _, c in ipairs(kids(node)) do
      if c.name == "AstroModel" then model = c end
    end
  end
  if model and not (nodes.helmet and nodes.helmet.valid) then
    nodes = {}
    for _, c in ipairs(kids(model)) do
      if c.name == NODE_NAMES.helmet then nodes.helmet = c end
    end
    for _, c in ipairs(kids(nodes.helmet)) do
      if c.name == NODE_NAMES.visor then nodes.visor = c end
      if c.name == NODE_NAMES.lamps then nodes.lamps = c end
    end
  end
end

-- The suit's parts drawn as the state says, and only while the body is: the
-- camera hides the body in first person (and the walker the model with it),
-- and a hidden parent hides these — set here as well, for any engine where
-- visibility is not inherited.
local function show()
  local body = model and model.valid and model.visible ~= false
  if nodes.helmet and nodes.helmet.valid then nodes.helmet.visible = body and helmet end
  if nodes.visor and nodes.visor.valid then nodes.visor.visible = body and helmet and visor end
  if nodes.lamps and nodes.lamps.valid then nodes.lamps.visible = body and helmet and lamps end
end

local function persist()
  if not (save and save.set) then return end
  save.set("crew.helmet", helmet and 1 or 0)
  save.set("crew.visor", visor and 1 or 0)
  save.set("crew.lamps", lamps and 1 or 0)
end

local function load_state()
  if loaded or not (save and save.get) then return end
  loaded = true
  helmet = (save.get("crew.helmet") or 1) ~= 0
  visor = (save.get("crew.visor") or 1) ~= 0
  lamps = (save.get("crew.lamps") or 1) ~= 0
end

-- ── the air ─────────────────────────────────────────────────────────────────

local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end

-- The air where the crew stands: ok, reason. `x, y, z` the crew's world
-- position (the walker's node).
function breathableAt(x, y, z)
  local dom = space and space.dominant and space.dominant(x, y, z)
  local cl = ref("climate")
  local w = dom and cl and cl.worldOf and cl.worldOf(dom)
  if not w or (w.atmo or 0) < 0.05 then
    return false, "There is no air here. The helmet stays on."
  end
  local ae = ref("aero")
  local oxy
  if ae and ae.oxygen then
    oxy = ae.oxygen(w)
  else
    -- (aero's rule, for a scene without the AeroLib: the home world and the
    -- living worlds breathe, the rest do not)
    local geo = w.geo
    oxy = (type(geo) == "table" and (geo.home or ({ archipelago = 1, verdant = 1, alpine = 1, steppe = 1,
      tundra = 1, dune = 0.8 })[geo.type or ""])) and 1 or (type(geo) ~= "table" and (w.atmo or 0) > 0.3 and 1 or 0)
  end
  if (oxy or 0) < 0.5 then
    return false, "This air has no oxygen to breathe. The helmet stays on."
  end
  local b = space.body and space.body(dom)
  if b then
    local alt = len(x - b.x, y - b.y, z - b.z) - (w.radius or b.radius or 0)
    local H = (w.atmoHeight or 0) > 0 and w.atmoHeight or 0.35 * (w.radius or b.radius or 800)
    local share
    if ae and ae.airShare then
      share = ae.airShare(math.max(alt, -0.25 * H), H, w.atmoScaleH)
    else
      local f = math.max(0, 1 - math.max(alt, 0) / H)
      share = f * f
    end
    if share * math.min(1, (w.atmo or 0) / 0.45) < P.thin_air then
      return false, "The air is too thin to breathe up here. The helmet stays on."
    end
  end
  local tk = type(w.bio) == "table" and w.bio.tempK or nil
  if tk and tk < P.cold_k then
    return false, string.format("It is %d °C out there. Too cold to take the helmet off.", math.floor(tk - 273.15))
  end
  if tk and tk > P.hot_k then
    return false, string.format("It is %d °C out there. Too hot to take the helmet off.", math.floor(tk - 273.15))
  end
  return true, nil
end

-- May the helmet come off here, now? ok, reason.
function canRemoveHelmet()
  local wk = ref("planet_walker")
  if busy then return false, "Hands full: the neck ring is still turning." end
  if not wk then return false, "The crew isn't here." end
  if wk.downed then return false, "The crew is out cold." end
  if not wk.onFoot then return false, "Only on foot." end
  if wk.headUnder or wk.swimming then return false, "Not under water." end
  local n = self_node or (wk.node)
  if not n then return false, "The crew isn't here." end
  return breathableAt(n.x, n.y, n.z)
end

function helmetOn() return helmet end
function visorDown() return visor end
function lampsOn() return lamps end

function breathMult()
  if helmet then return 1.0 end
  return P.breath_hold
end

local function sound(off)
  if not (audio and audio.play) then return end
  local n = self_node
  local o = { track = "SFX", volume = 0.35, minDistance = 2, maxDistance = 20, pitch = off and 1.08 or 0.92 }
  local clip = string.format("audio/kenney/impact/impactPlate_light_%03d.ogg", math.random(0, 4))
  if n and n.valid ~= false then audio.play(clip, n, o) else audio.play(clip, o) end
  -- the seal: a short hiss as the ring lets go (or seats)
  local hiss = (math.random() < 0.5) and "audio/foley/hiss_seal.ogg" or "audio/foley/hiss_cylinder.ogg"
  local o2 = { track = "SFX", volume = 0.30, minDistance = 2, maxDistance = 14, pitch = off and 1.08 or 0.95 }
  if n and n.valid ~= false then audio.play(hiss, n, o2) else audio.play(hiss, o2) end
  if caption then caption(off and "helmet unlatched" or "helmet locked") end
end

local function apply(on, quiet)
  if helmet == on then return end
  helmet = on
  changes = changes + 1
  persist()
  show()
  if not quiet then sound(not on) end
end

-- nil if the helmet may go to `want` (true = on) now, else the reason.
function helmetRefusal(want)
  if busy then return "Hands full: the neck ring is still turning." end
  if want or not helmet then return nil end
  local ok, why = canRemoveHelmet()
  if ok then return nil end
  return why
end

-- An option from a plain table (callers pass a node there, too).
local function opt(opts, key)
  if type(opts) ~= "table" then return nil end
  return rawget(opts, key)
end

-- Helmet on or off. ok, reason.
function setHelmet(on, opts)
  on = on and true or false
  if busy then return false, "Hands full: the neck ring is still turning." end
  if on == helmet then return true, nil end
  if not on then
    local ok, why = canRemoveHelmet()
    if not ok then lastReason = why return false, why end
  end
  lastReason = nil
  if opt(opts, "instant") or not (model and model.valid) then
    apply(on, opt(opts, "quiet"))
    return true, nil
  end
  busy = true
  anim.t, anim.want, anim.flipped = 0, on, false
  return true, nil
end

function toggleHelmet() return setHelmet(not helmet) end

function setVisor(down)
  down = down and true or false
  if not helmet and not down then return false, "The helmet is off." end
  visor = down
  persist()
  show()
  if audio and audio.play then
    audio.play(string.format("audio/foley/switch_%d.ogg", math.random(1, 5)),
      { track = "SFX", volume = 0.18 })
  end
  return true, nil
end

function setLamps(on)
  lamps = on and true or false
  persist()
  show()
  if audio and audio.play then
    audio.play(lamps and "audio/foley/toggle_on.ogg" or "audio/foley/toggle_off.ogg", { track = "SFX", volume = 0.30 })
  end
  return true, nil
end

-- ── the hands at the neck ring ──────────────────────────────────────────────
-- Both hands go up to the ring either side of the neck, turn it, and come
-- down, the helmet changing hands at the middle. Arm IK on the clips (the
-- tool's hold included) for those seconds only; the targets are rebuilt from
-- the bones every frame, in the frame they are used (the planet moves).

local function vsub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
local function vnorm(a)
  local l = len(a[1], a[2], a[3])
  if l < 1e-6 then return { 0, 0, 0 } end
  return { a[1] / l, a[2] / l, a[3] / l }
end
local function cross(a, b)
  return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] }
end
local function bp(name)
  local v = model and model.bonePos and model:bonePos(name)
  if not v then return nil end
  return { v.x, v.y, v.z }
end

local function hands(dt)
  local T = math.max(0.3, P.anim_secs)
  anim.t = anim.t + dt
  local u = anim.t / T
  if u >= 0.5 and not anim.flipped then
    anim.flipped = true
    apply(anim.want)
  end
  if u >= 1 then
    busy = false
    if not anim.flipped then apply(anim.want) end
    return
  end
  local a = model and model.animator and model:animator()
  local head, hip = bp("Head"), bp("Hip")
  local sl, sr = bp("Upperarm.Left"), bp("Upperarm.Right")
  if not (a and a.reach and head and hip and sl and sr) then return end
  local left = vnorm(vsub(sl, sr))                  -- the crew's left
  local up = vnorm(vsub(head, hip))
  local fwd = vnorm(cross(left, up))
  -- up to the ring by 30 %, at it until 70 %, down by the end
  local w = u < 0.3 and (u / 0.3) or (u > 0.7 and (1 - u) / 0.3 or 1)
  w = w * w * (3 - 2 * w)
  local twist = math.sin(math.min(1, math.max(0, (u - 0.3) / 0.4)) * math.pi) * 0.03
  for _, side in ipairs({ { "Left", 1 }, { "Right", -1 } }) do
    local s = side[2]
    local t = {}
    local pole = {}
    for i = 1, 3 do
      t[i] = head[i] + left[i] * s * 0.135 + fwd[i] * (0.035 + twist * s) + up[i] * 0.035
      pole[i] = t[i] + left[i] * s * 0.35 - up[i] * 0.30 + fwd[i] * 0.05
    end
    a:reach("Hand." .. side[1], vec3(t[1], t[2], t[3]), { weight = w, pole = vec3(pole[1], pole[2], pole[3]) })
  end
end

-- ── the frame ───────────────────────────────────────────────────────────────

function start(node)
  self_node = node
  load_state()
end

function update(node, dt)
  self_node = node
  load_state()
  resolve(node)
  local wk = ref("planet_walker")
  -- Bare-headed where the air has stopped being breathable: back on at once.
  if not helmet and not busy and wk and wk.onFoot and not wk.downed then
    local ok, why = breathableAt(node.x, node.y, node.z)
    if not ok then
      apply(true, not checked_load)
      if checked_load then
        local bc = ref("big_caption")
        if bc and bc.show then bc.show("HELMET ON", why or "", 3.0) end
      end
    end
    checked_load = true
  elseif wk and wk.onFoot then
    checked_load = true
  end
  show()
end

-- For a probe (tools/perf/suitshots.lua): drive the left arm through the
-- shoulder's range, { kind = "abd" | "flex", deg = 0..170 } from arms-down,
-- built here from the bones in the frame it is used (the planet moves between
-- a probe's update and this). Cleared after each frame.
probeArm = nil

local function probe_arm()
  local pa = probeArm
  probeArm = nil
  local a = model and model.animator and model:animator()
  local head, hip = bp("Head"), bp("Hip")
  local sl, sr, el, hl = bp("Upperarm.Left"), bp("Upperarm.Right"), bp("Forearm.Left"), bp("Hand.Left")
  if not (a and a.reach and head and hip and sl and sr and el and hl) then return end
  local left = vnorm(vsub(sl, sr))
  local up = vnorm(vsub(head, hip))
  local fwd = vnorm(cross(left, up))
  local L = (len(el[1] - sl[1], el[2] - sl[2], el[3] - sl[3]) + len(hl[1] - el[1], hl[2] - el[2], hl[3] - el[3])) * 0.96
  local r = math.rad(pa.deg or 0)
  local side = pa.kind == "flex" and fwd or left
  local t, pole = {}, {}
  for i = 1, 3 do
    local d = -up[i] * math.cos(r) + side[i] * math.sin(r)
    t[i] = sl[i] + d * L
    pole[i] = sl[i] - fwd[i] * 0.4 - up[i] * 0.1
  end
  a:reach("Hand.Left", vec3(t[1], t[2], t[3]), { weight = 1, pole = vec3(pole[1], pole[2], pole[3]) })
end

function lateUpdate(node, dt)
  if busy then hands(dt or 0) end
  if probeArm then probe_arm() end
  show()
end
