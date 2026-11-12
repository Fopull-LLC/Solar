-- MEDICAL BAY — the spaceport's clinic between the Research Lab and the VAB
-- (missions plan M1; Ty 2026-11-11: "a new medical bay building on the home
-- base that should be connected to the lab. It should have a drive-in area
-- and a walk-in from the lab. It's used for these missions and also
-- full-healing your astronauts: when you go in there and talk to them they
-- heal you for free"). Runs on FacMedical's root (tools/base_buildings.py
-- medical(), written by tools/gen_base.py); its interior (prefabs/
-- MedInterior, tools/gen_medical.py) and its glazed link to the lab's east
-- wall (prefabs/MedLink) share its origin, spawned by base_facilities.
--
--   * THE MEDIC, Dr Imke Rao (prefabs/LabScientist with scientist.lua bound
--     to this building), stands by Bed 1 at the crash cart. E at her (or
--     right-click → Talk): the camera eases into a medium shot, and the talk
--     plays through the career beat runner (scenario_run.runBeats: the
--     scenario plate with her LIVE portrait, a render target filmed while
--     you talk). Hurt, dosed or knocked about, "Patch me up" heals you fully
--     and free: hp, the radiation dose, a downed wound, the heat (crew.
--     medTreat), and she tells you what was wrong (crew.lastCause). A crew
--     member hurt at the base: "See to <name>". Nothing wrong: a line or two
--     and no menu at all (few popups).
--   * ADMIT: a survivor (crew.clients, missions N1) carried in, walked in,
--     or seated in a craft parked on the bay floor is taken in: laid on Bed
--     2, treated, `admitted` in the save (medical.admitted), the contract's
--     survivor goal can latch (missions.survivorAdmitted), the feat medevac
--     (its first opens the Stretcher at the depot). The bay is the home
--     world's rescue delivery point.
--   * THE DRIVE-IN: inBay is the repair bay's box over the bay floor
--     (`Bay Floor` marker); a craft standing in it is noticed at 4 Hz while
--     the crew is within 300 m (craftIn, for probes and admit).
--   * THE INTERIOR and the medic's body are drawn only within `near` m of
--     the bay (the shell's solids stay: they are FacMedical's own boxes),
--     with the room's air handling (a real recorded fan, quiet) under it.
--   * WHERE: on an old save the bay keeps clear of the player's own
--     structures (base_facilities.medical_site); Ops tells you once where
--     it stands, one line on the strip.
--
-- FRAMES (docs/positions-and-frames.md). The bay is parented to its planet:
-- its node.x/y/z are body-relative and its axes never turn, so its frame is
-- kept body-relative and every point (markers, the medic, the bay box) is
-- placed against the planet's drawn position the frame it is used. The talk
-- camera and the portrait camera are placed from the medic's head as drawn,
-- every frame (lateUpdate). Nothing world is kept across frames.

defaults = {
  --@range 20 200 --@units m
  near = 60.0,           -- the interior and the medic are drawn within this
  --@range 1 4 --@units m
  reach = 2.4,           -- the talk prompt at the medic
  --@range 3 10 --@units m
  leave = 5.5,           -- walking this far from her ends the talk
  --@range 0.3 3 --@units s
  blend = 0.9,           -- the camera's ease in and out
}

local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or r.valid == false then r = findScript and findScript(kind) or nil; refs[kind] = r end
  return r
end
local function valid(n) return n ~= nil and n.valid ~= false end
local function len(x, y, z) return math.sqrt(x * x + y * y + z * z) end
local function child(n, name)
  if not valid(n) then return nil end
  for _, c in ipairs(n:children() or {}) do if c.name == name then return c end end
  return nil
end
local function now() return time or 0 end
local function say_log(s) if log then log("medical: " .. s) end end

ROOT = nil
body_name = nil
interior = nil
link = nil
linked = false            -- (published; lab.lua opens its Med Door only then)
inside = false            -- the interior is drawn
medic = nil               -- the medic's node
craftIn = nil             -- { name, t } a craft standing on the bay floor (probes)
lastAdmit = nil           -- { id, name, t, how }
lastTalk = nil            -- { t, beats, treated } (probes)
forceInside = false       -- probes keep the interior on

MEDIC = { name = "Imke Rao", title = "Dr Imke Rao", role = "Medical officer", spot = "Med 1", seed = 1207 }
-- the drive-in box over the bay floor (the repair bay's, a shade longer)
BAY = { hx = 3.0, hz = 5.5, top = 4.0 }
-- the whole room (inside the walls), for admitting someone on foot
ROOM = { x0 = -6.2, x1 = 6.2, z0 = -8.2, z1 = 8.2, top = 4.5 }

-- ── pure (tests) ────────────────────────────────────────────────────────────
-- Is a point in the bay's frame (x right, y up, z to the door; metres from
-- the `Bay Floor` marker c = { x, y, z }) inside the drive-in box?
function inBayLocal(lx, ly, lz, c)
  c = c or { x = 0, y = 0, z = 0 }
  local dx, dy, dz = lx - c.x, ly - c.y, lz - c.z
  return math.abs(dx) <= BAY.hx and math.abs(dz) <= BAY.hz and dy >= -0.6 and dy <= BAY.top
end
-- Inside the room (the shell's ground frame relative to `floor` = the
-- marker's ground-frame point and its offset from the origin)?
function inRoomLocal(gx, gy, gz)
  return gx >= ROOM.x0 and gx <= ROOM.x1 and gz >= ROOM.z0 and gz <= ROOM.z1 and gy >= -0.8 and gy <= ROOM.top
end

-- WHAT SHE SAYS. Short, dry, kind under it: a field medic who has seen what
-- this planet does to people. {name}: who she talks to (first name).
LINES = {
  hello = {
    "You look fine. Annoyingly fine.",
    "Nothing broken? Good. Keep it that way.",
    "Quiet day. I like quiet days.",
    "If you're here for the coffee, it's terrible. I make it that way on purpose.",
  },
  hello_hurt = {
    "You're moving like it hurts. Sit down.",
    "Let me see that. No, don't touch it.",
    "{name}. You walked in, which is something. Over here.",
  },
  ask = "What do you need?",
  bed = {
    "Up on the bed. This won't take long.",
    "Jacket off. Breathe normally. I said normally.",
  },
  cause = {
    impact = "Hairline fracture in the shin and a lot of bruising. You fell, and you landed badly.",
    shot = "A burn track along the ribs. Whatever hit you was hot. The dressing will itch for a week.",
    radiation = "Your dosimeter has been busy. Iodide and chelation; drink more water than you want to.",
    air = "You ran your suit dry. Mild hypoxia; your lips were grey when you came in.",
    oxygen = "You ran your suit dry. Mild hypoxia; your lips were grey when you came in.",
    hypoxia = "Thin air and too much effort. Oxygen, then you sit still for an hour.",
    gas = "You breathed something you shouldn't have. Lungs are clear now. Watch the gas readings down there.",
    cold = "Early frostbite on two fingers. Warm saline, slowly. Keep your gloves sealed.",
    heat = "First-degree burns, mostly the neck. Cooling gel. Stay out of that heat.",
    hotair = "Scalded airway, mild. Humidified oxygen. You'll sound like a frog till tomorrow.",
    crushed = "Two cracked ribs. Breathe through it. Tape and something for the pain.",
    drowned = "Water in the lungs. You're lucky; most people aren't.",
    explosion = "Blast bruising and a perforated eardrum. It'll heal. Stop standing next to things that explode.",
    cabin = "Whiplash and a mild concussion. Follow my finger. Good.",
  },
  cause_none = "Cuts, bruises, a pulled shoulder. Nothing that won't mend.",
  dose = "And your dose was up. That's flushed out too.",
  done = {
    "There. Fit to go back out. Try to come back in one piece.",
    "Done. Same time next week, I expect.",
    "You're good. Go on, before I find something else.",
  },
  member = "I'll look in on {member} in quarters. They'll be on their feet by tonight.",
  bye = { "Mind the wet floor.", "Go on, then.", "Door's that way." },
  admit = {
    "Bed two. I've got them. You did well getting them here.",
    "Easy, easy. On three. I've got them now.",
    "Let's have a look at you. You're safe now. You're in the medical bay.",
  },
}
-- (pure) a line from a list, steady for a seed
function pick(list, seed)
  if type(list) ~= "table" then return list end
  return list[1 + (math.floor(seed or 0) % #list)]
end
local function fill(s, t)
  return (tostring(s or ""):gsub("{(%w+)}", function(k) return t[k] and tostring(t[k]) or ("{" .. k .. "}") end))
end
-- (pure) the talk as beats for the career runner. st = { name (first name),
-- needs (crew.medNeeds), cause, member = { id, name } | nil, seed }
function talkBeats(st)
  local seed = st.seed or 0
  local hurt = st.needs and st.needs.any
  local t = { name = st.name or "you", member = st.member and st.member.name }
  local out = {}
  out[#out + 1] = { say = { who = "rao", text = fill(pick(hurt and LINES.hello_hurt or LINES.hello, seed), t), with = "player" } }
  local opts = {}
  if hurt then opts[#opts + 1] = { text = "Patch me up", hook = "treat_self" } end
  if st.member then opts[#opts + 1] = { text = "See to " .. st.member.name, hook = "treat_member" } end
  if #opts == 0 then return out end            -- nothing to do: no menu
  opts[#opts + 1] = { text = "Nothing. Just saying hello", beats = { { say = { who = "rao", text = pick(LINES.bye, seed + 1) } } } }
  out[#out + 1] = { choice = { who = "rao", prompt = LINES.ask, options = opts } }
  return out
end
-- (pure) the treatment's beats once she has you on the bed: a line, the
-- shot of her working (5 s), the treatment itself (hook), what it was
function treatBeats(seed)
  return {
    { say = { who = "rao", text = pick(LINES.bed, seed), with = "player" } },
    { sound = "audio/foley/hiss_cylinder.ogg" },
    { shot = { from = "med:cam", look = "med:head", secs = 5.0, offset = { 0, 0, 0 }, lookOffset = { 0, -1.2, 0 } } },
    { hook = "treat_apply" },
  }
end
-- (pure) what she says after: the cause, the dose, the send-off
function resultLines(before, seed)
  local out = {}
  if not before then return out end
  out[#out + 1] = (before.cause and LINES.cause[before.cause]) or LINES.cause_none
  if (before.dose or 0) > 0.005 and before.cause ~= "radiation" then out[#out + 1] = LINES.dose end
  out[#out + 1] = pick(LINES.done, seed)
  return out
end

-- ── the bay's frame, body-relative ──────────────────────────────────────────
local F = nil             -- { o, ex, ey, ez }
local function frame_of(node)
  local w0 = node:toWorld(vec3(0, 0, 0))
  local function dir(x, y, z)
    local p = node:toWorld(vec3(x, y, z))
    return { x = p.x - w0.x, y = p.y - w0.y, z = p.z - w0.z }
  end
  return { o = { x = node.x, y = node.y, z = node.z }, ex = dir(1, 0, 0), ey = dir(0, 1, 0), ez = dir(0, 0, 1) }
end
local function to_body(lx, ly, lz)
  return { x = F.o.x + F.ex.x * lx + F.ey.x * ly + F.ez.x * lz,
           y = F.o.y + F.ex.y * lx + F.ey.y * ly + F.ez.y * lz,
           z = F.o.z + F.ex.z * lx + F.ey.z * ly + F.ez.z * lz }
end
local function to_local(p)
  local dx, dy, dz = p.x - F.o.x, p.y - F.o.y, p.z - F.o.z
  return dx * F.ex.x + dy * F.ex.y + dz * F.ex.z, dx * F.ey.x + dy * F.ey.y + dz * F.ey.z, dx * F.ez.x + dy * F.ez.y + dz * F.ez.z
end
-- a marker's point, body-relative (nil before the building is there)
local function mark_body(name, lift)
  local m = child(ROOT, name)
  if not (m and F) then return nil end
  return to_body(m.x, m.y + (lift or 0), m.z)
end
-- (the Bay Floor marker sits at ground y 0.12: the ground frame's origin
-- is that marker's ground point less its offset, as gen_base prints it)
local floor_c = nil       -- the Bay Floor marker, prefab-local
local origin_g = nil      -- the prefab origin in the shell's ground frame (FacMedical row's ox, seat, oz)
local function ground_of_local(lx, ly, lz)
  if not origin_g then return nil end
  return lx + origin_g.x, ly + origin_g.y, lz + origin_g.z
end

-- A world point (drawn this frame) → is it in the drive-in box / the room?
function inBay(wx, wy, wz)
  if not (F and floor_c and body_name) then return false end
  local b = space.body(body_name)
  if not b then return false end
  local lx, ly, lz = to_local({ x = wx - b.x, y = wy - b.y, z = wz - b.z })
  return inBayLocal(lx, ly, lz, floor_c)
end
function inRoom(wx, wy, wz)
  if not (F and body_name) then return false end
  local b = space.body(body_name)
  if not b then return false end
  local lx, ly, lz = to_local({ x = wx - b.x, y = wy - b.y, z = wz - b.z })
  local gx, gy, gz = ground_of_local(lx, ly, lz)
  return gx ~= nil and inRoomLocal(gx, gy, gz)
end

-- ── the interior ────────────────────────────────────────────────────────────
local function find_tagged_near(tag)
  for _, n in ipairs((findTagged and findTagged(tag)) or {}) do
    if valid(n) and len(n.x - ROOT.x, n.y - ROOT.y, n.z - ROOT.z) < 0.5 then return n end
  end
  return nil
end
local function medic_show(on)
  if not valid(medic) then return end
  for _, c in ipairs(medic:children() or {}) do if c.enabled ~= on then c.enabled = on end end
end
local hum = nil
local function set_inside(on)
  if on == inside then return end
  inside = on
  if valid(interior) then
    if interior.enabled == false then interior.enabled = true end
    for _, c in ipairs(interior:children() or {}) do if c.enabled ~= on then c.enabled = on end end
  end
  medic_show(on)
  -- the room's air handling: a real recorded fan, low, at the bay
  if on and not hum and audio and audio.play and valid(ROOT) then
    local ok, h = pcall(audio.play, "audio/plant/fan_loop.ogg", ROOT, { loop = true, minDistance = 3, maxDistance = 22, track = "SFX", volume = 0.16, pitch = 0.82 })
    if ok then hum = h end
  elseif not on and hum then
    pcall(function() if hum.stop then hum:stop() end end)
    hum = nil
  end
  say_log("interior " .. (on and "on" or "off"))
end

-- ── the medic ───────────────────────────────────────────────────────────────
local medic_spawned = false
local function spawn_medic()
  if medic_spawned or not (spawn and F and valid(ROOT)) then return end
  local b = space.body(body_name)
  local spot, look = child(ROOT, MEDIC.spot), child(ROOT, MEDIC.spot .. " Look")
  if not (b and spot and look) then return end
  medic_spawned = true
  local up = F.ey
  local ul = len(up.x, up.y, up.z)
  up = { x = up.x / ul, y = up.y / ul, z = up.z / ul }
  local p = to_body(spot.x, spot.y, spot.z)
  local q = to_body(look.x, look.y, look.z)
  local f = { x = q.x - p.x, y = q.y - p.y, z = q.z - p.z }
  local dv = f.x * up.x + f.y * up.y + f.z * up.z
  f = { x = f.x - up.x * dv, y = f.y - up.y * dv, z = f.z - up.z * dv }
  local fl = len(f.x, f.y, f.z)
  f = { x = f.x / fl, y = f.y / fl, z = f.z / fl }
  local h = 0.99
  spawn("LabScientist", vec3(b.x + p.x + up.x * h, b.y + p.y + up.y * h, b.z + p.z + up.z * h), function(n)
    n.x, n.y, n.z = p.x + up.x * h, p.y + up.y * h, p.z + up.z * h
    pcall(n.setUp, n, vec3(up.x, up.y, up.z), vec3(-f.x, -f.y, -f.z))
    n.name = "MedicRao"
    local sc = n.getScript and n:getScript("scientist")
    if sc and sc.bind then sc.bind(20, MEDIC, F, child(ROOT, MEDIC.spot .. " Hands"), look, ROOT) end
    medic = n
    medic_show(inside)
    say_log("Dr Rao at her post")
  end, ROOT.parent)
end
-- (facility_menu's prompt) the medic within reach of the avatar: her node, d
function nearMedic(a, reach)
  if not (valid(a) and valid(medic) and inside) then return nil end
  -- (her node is parented to the planet: its x/y/z are body-relative; the
  -- avatar's are world. Both drawn, this frame: worldPos)
  local m = medic.worldPos
  local d = len(a.x - m.x, a.y - m.y, a.z - m.z)
  if d < (reach or params.reach or 2.4) then return { node = medic, d = d, staff = MEDIC } end
  return nil
end
function isMedic(node)
  local n, k = node, 0
  while valid(n) and valid(medic) and k < 5 do
    if n.id == medic.id then return true end
    n = n.parent
    k = k + 1
  end
  return false
end

-- ── the medic's head, the shots (drawn poses, this frame) ───────────────────
local function face_node()
  for _, c in ipairs(valid(medic) and medic:children() or {}) do
    if c.name == "LabModel" then
      for _, k in ipairs(c:children() or {}) do if k.name == "Face" then return k end end
    end
  end
  return nil
end
local function head_frame()
  if not valid(medic) then return nil end
  local fn = face_node()
  local h = (fn and fn.worldPos) or medic:toWorld(vec3(0, 0.72, 0))
  local o = medic.worldPos
  local sc = medic.getScript and medic:getScript("scientist")
  local s = (sc and sc.faceSign) or 1
  local f = medic:toWorld(vec3(0, 0, s))
  local u = medic:toWorld(vec3(0, 1, 0))
  local r = medic:toWorld(vec3(s, 0, 0))
  return h, { x = f.x - o.x, y = f.y - o.y, z = f.z - o.z }, { x = u.x - o.x, y = u.y - o.y, z = u.z - o.z },
         { x = r.x - o.x, y = r.y - o.y, z = r.z - o.z }
end
local talk_spot = nil
local function talk_shot()
  return function()
    local h, f, u, r = head_frame()
    if not h then return nil end
    local sp = talk_spot or { 1.75, -1.25, 0.12 }
    local c = { x = h.x + f.x * sp[1] + r.x * sp[2] + u.x * sp[3], y = h.y + f.y * sp[1] + r.y * sp[2] + u.y * sp[3],
                z = h.z + f.z * sp[1] + r.z * sp[2] + u.z * sp[3] }
    -- her on the left third, the plate low on the screen
    local vx, vy, vz = h.x - c.x, h.y - c.y, h.z - c.z
    local cx_, cy_, cz_ = vy * u.z - vz * u.y, vz * u.x - vx * u.z, vx * u.y - vy * u.x
    local cl = len(cx_, cy_, cz_)
    if cl < 1e-6 then return c.x, c.y, c.z, h.x, h.y, h.z, u.x, u.y, u.z end
    local d = len(vx, vy, vz)
    local aside, adrop = 0.40 * d / 2.15, 0.22
    return c.x, c.y, c.z, h.x + cx_ / cl * aside - u.x * adrop, h.y + cy_ / cl * aside - u.y * adrop,
           h.z + cz_ / cl * aside - u.z * adrop, u.x, u.y, u.z
  end
end
-- the career runner's refs for the treatment shot: a point off her right
-- shoulder, low, and her head (body-relative, re-read every frame)
local function rel_of(w)
  local d = space.dominant(w.x, w.y, w.z)
  local b = d and space.body(d)
  return b and { body = d, x = w.x - b.x, y = w.y - b.y, z = w.z - b.z } or nil
end
local REFS = {
  ["med:head"] = function()
    local h = head_frame()
    return h and rel_of(h) or nil
  end,
  ["med:cam"] = function()
    local h, f, u, r = head_frame()
    if not h then return nil end
    -- (in front and to her right, at her eye height: the runner keeps a shot
    -- 1.1 m off what it looks at, and in closer the camera was pushed up
    -- over her head)
    return rel_of({ x = h.x + f.x * 1.35 + r.x * 0.75 + u.x * 0.05, y = h.y + f.y * 1.35 + r.y * 0.75 + u.y * 0.05,
                    z = h.z + f.z * 1.35 + r.z * 0.75 + u.z * 0.05 })
  end,
  ["med:bed2"] = function() local p = mark_body("Bed 2"); return p and { body = body_name, x = p.x, y = p.y, z = p.z } end,
}

-- ── the live portrait (a render target filmed while you talk) ───────────────
local pcam = nil
local pcam_making = false
local function portrait_on(on)
  if on and not valid(pcam) and not pcam_making and createNode and valid(ROOT) then
    pcam_making = true
    createNode("MedicPortraitCam", ROOT.parent, function(n)
      pcam_making = false
      pcam = n
      pcall(function()
        n:setCamera { target = "medic_face", width = 192, height = 192, hz = 15, fovY = 0.42, active = false,
                      near = 0.05, far = 60, shadows = false, terrain = false }
      end)
      n.enabled = true
    end)
  end
  if valid(pcam) and pcam.enabled ~= on then pcam.enabled = on end
end
local function portrait_place()
  if not (valid(pcam) and pcam.enabled) then return end
  local h, f, u = head_frame()
  if not h then return end
  local d = 0.85
  local cx, cy, cz = h.x + f.x * d + u.x * 0.02, h.y + f.y * d + u.y * 0.02, h.z + f.z * d + u.z * 0.02
  local pw = ROOT.parent and ROOT.parent.worldPos
  if not pw then return end
  -- (parented to the planet: local is body-relative)
  pcam.x, pcam.y, pcam.z = cx - pw.x, cy - pw.y, cz - pw.z
  pcall(pcam.lookAt, pcam, vec3(h.x - u.x * 0.05, h.y - u.y * 0.05, h.z - u.z * 0.05), vec3(u.x, u.y, u.z))
end

-- ── the talk ────────────────────────────────────────────────────────────────
local talking = false
local admit_talk = false
local reshot = false
local talk_vars = {}
function isTalking() return talking end
local function first_name(n) return tostring(n or ""):match("^(%S+)") or tostring(n or "") end
local function crew_hurt_at_base(C, active)
  local best, bh = nil, 2
  for _, r in ipairs((C.roster and C.roster()) or {}) do
    if r.status == "base" and r.id ~= active then
      local n = C.medNeeds and C.medNeeds(r)
      if n and n.any and n.hp < bh then best, bh = r, n.hp end
    end
  end
  return best
end
local function cast()
  return { rao = { name = MEDIC.title, tag = "MEDICAL OFFICER", color = { 0.86, 0.52, 0.46 }, portrait = "rt:medic_face" } }
end
local end_talk
local function hooks()
  return {
    treat_self = function(api)
      api.beats(treatBeats(talk_vars.seed or 0))
    end,
    treat_apply = function(api)
      local C = ref("crew")
      local id = C and C.activeId and C.activeId()
      local before = id and C.medTreat and C.medTreat(id, "Dr Rao")
      talk_vars.treated = before and true or false
      if lastTalk then lastTalk.treated = talk_vars.treated; lastTalk.before = before end
      -- the camera back on her once the runner's shot has let go (it clears
      -- its own on the next tick: update puts hers back after that)
      reshot = true
      local list = {}
      for _, l in ipairs(resultLines(before, talk_vars.seed or 0)) do list[#list + 1] = { say = { who = "rao", text = l, with = "player" } } end
      api.beats(list)
    end,
    treat_member = function(api)
      local C = ref("crew")
      local m = talk_vars.member
      if C and m and C.medTreat then C.medTreat(m.id, "Dr Rao") end
      api.beats({ { say = { who = "rao", text = fill(LINES.member, { member = m and first_name(m.name) or "them" }) } } })
    end,
  }
end
function talk()
  if talking then return false, "already talking" end
  local run, C = ref("scenario_run"), ref("crew")
  if not (run and run.runBeats and C and valid(medic)) then return false, "no medic" end
  local id = C.activeId and C.activeId()
  local r = id and C.get(id)
  if not r then return false, "nobody" end
  local visits = (tonumber(save.get("medical.visits")) or 0) + 1
  save.set("medical.visits", visits)
  local member = crew_hurt_at_base(C, id)
  talk_vars = { seed = visits, member = member and { id = member.id, name = member.name } or nil }
  local beats = talkBeats({ name = first_name(r.name), needs = C.medNeeds and C.medNeeds(r), cause = C.lastCause and C.lastCause(id),
                            member = talk_vars.member, seed = visits })
  -- ("player" in a say's `with`: the member you are, by name and role)
  local ok, why = run.runBeats(beats, { id = "medic", cast = cast(), vars = talk_vars, refs = REFS, hooks = hooks(), crew = { player = id },
                                        onDone = function(_, w) end_talk(w) end })
  if not ok then return false, why end
  talking = true
  lastTalk = { t = now(), beats = #beats, treated = false }
  -- the medium shot, her spot picked clear of the cart and the beds (lab_talk's casts)
  local lt = ref("lab_talk")
  talk_spot = nil
  if lt and lt.pickSpot then
    local okp, sp = pcall(lt.pickSpot, { node = medic }, false)
    if okp and type(sp) == "table" then talk_spot = sp end
  end
  local pc = ref("planet_camera")
  if pc and pc.setShot then pc.setShot(talk_shot(), params.blend or 0.9) end
  portrait_on(true)
  forceInside = true
  local cm = ref("context_menu")
  if cm and cm.isOpen and cm.isOpen() and cm.close then cm.close() end
  say_log("talk with " .. tostring(r.name))
  return true
end
end_talk = function(why)
  if not talking then return end
  talking = false
  reshot = false
  forceInside = false
  if not admit_talk then portrait_on(false) end
  local pc = ref("planet_camera")
  if pc and pc.clearShot then pcall(pc.clearShot, params.blend or 0.9) end
  local run = ref("scenario_run")
  if why ~= "done" and run and run.stopBeats then pcall(run.stopBeats, why or "closed", "medic") end
  say_log("talk ends (" .. tostring(why) .. ")")
end
function endTalk(why) end_talk(why or "closed") end

-- ── admitting survivors ─────────────────────────────────────────────────────
local function admitted_tbl() local t = save.get("medical.admitted"); return type(t) == "table" and t or {} end
function isAdmitted(id) return admitted_tbl()[tostring(id)] ~= nil end
function admittedCount() local n = 0; for _ in pairs(admitted_tbl()) do n = n + 1 end return n end
-- Take survivor `id` in: Bed 2, treated, the save, the contract, the feat.
-- `how`: "carried" | "walked" | "craft". → true | false, why
function admit(id, how)
  local C = ref("crew")
  local r = C and C.get and C.get(id)
  if not r then return false, "nobody" end
  if not r.client then return false, "not a survivor" end
  if r.status == "dead" then return false, (r.name or "they") .. " is dead" end
  if isAdmitted(id) then return false, "already admitted" end
  local b = space.body(body_name or "")
  local bed, head = mark_body("Bed 2"), mark_body("Bed 2 Head")
  if not (b and bed) then return false, "the bay isn't there" end
  -- out of a seat, off a back
  if r.status == "aboard" then
    local v = C.craftOf and C.craftOf(id)
    if v and v.unseatMember then pcall(v.unseatMember, id) end
  end
  if C.carrying and C.carrying() == id then save.set("crew.carrying", false) end
  local f = false
  if head then
    local dx, dy, dz = head.x - bed.x, head.y - bed.y, head.z - bed.z
    local l = len(dx, dy, dz)
    if l > 1e-3 then f = { x = dx / l, y = dy / l, z = dz / l } end
  end
  -- (stand: where they get up, by the bed; the record's point is a step off it)
  local stand = mark_body("Med Centre") or bed
  C.patch(id, { status = "afoot", carriedBy = false, follow = false, craft = false, body = body_name,
                x = stand.x, y = stand.y + 0.0, z = stand.z, admitted = now(),
                pose = { kind = "lie", x = bed.x, y = bed.y, z = bed.z, f = f } })
  if C.medTreat then C.medTreat(id, "Dr Rao") end
  local t = admitted_tbl()
  t[tostring(id)] = { t = now(), client = r.client, name = r.name, how = how }
  save.set("medical.admitted", t)
  lastAdmit = { id = id, name = r.name, t = now(), how = how }
  say_log(string.format("admitted %s (#%d, %s)", tostring(r.name), id, tostring(how)))
  local FT = ref("feats")
  if FT and FT.mark then pcall(FT.mark, "medevac") end
  local M = ref("missions")
  if M and M.survivorAdmitted then pcall(M.survivorAdmitted, id, r.client) end
  -- her line, and the client's (mission_story's delivered beats when there are any)
  local run = ref("scenario_run")
  if run and run.runBeats then
    local list = { { say = { who = "rao", text = pick(LINES.admit, id) } } }
    local MS = ref("mission_story")
    local extra, cast2 = nil, cast()
    if MS and MS.beatsFor and type(r.client) == "string" then
      local okb, bl, cl = pcall(MS.beatsFor, r.client, "admitted", { name = r.name })
      if okb and type(bl) == "table" then extra = bl; for k, v in pairs(cl or {}) do cast2[k] = v end end
    end
    for _, x in ipairs(extra or {}) do list[#list + 1] = x end
    -- (her live picture on the plate while she speaks)
    admit_talk = true
    portrait_on(true)
    pcall(run.runBeats, list, { id = "admit:" .. tostring(id), cast = cast2, refs = REFS,
      onDone = function() admit_talk = false; if not talking then portrait_on(false) end end })
  end
  return true
end

-- where a survivor is this frame (world, drawn), and how they'd come in
local function survivor_at(C, r)
  if r.status == "carried" then
    local a = find and find("Astronaut")
    if valid(a) and C.carrying and C.carrying() == r.id then return a.x, a.y, a.z, "carried" end
    return nil
  end
  if r.status == "aboard" then
    local v = C.craftOf and C.craftOf(r.id)
    if v and valid(v.node) then return v.node.x, v.node.y, v.node.z, "craft" end
    return nil
  end
  if r.status == "afoot" then
    local n = C.bodyOf and C.bodyOf(r.id)
    if valid(n) then return n.x, n.y, n.z, "walked" end
    local b = r.body and space.body(r.body)
    if b and r.x then return b.x + r.x, b.y + r.y, b.z + r.z, "walked" end
  end
  return nil
end

-- ── the frame ───────────────────────────────────────────────────────────────
local look_t = -10
local bay_t = 0
local provider_on = false
local told = false
local t_born = nil
function start(node)
  ROOT = node
end

local function provider(t, ctx)
  if not (t and t.node and isMedic(t.node)) then return {} end
  return {
    { type = "action", id = "med_talk", label = talking and "Talking…" or "Talk", hint = "E",
      enabled = function() return not talking end, why = function() return "already talking" end,
      act = function() return talk() end },
  }, string.upper(MEDIC.title), "Medical officer · the Medical Bay"
end

-- Ops says once where the bay stands (a save that had none: an old save, or
-- a new one) — one line on the strip, nothing on screen
local function tell_once()
  if told then return end
  if save.get("medical.told") then told = true return end
  if now() - (t_born or now()) < 25 then return end
  local gm = ref("game_manager")
  if gm and (gm.loading or gm.curtain) then return end
  local strip = ref("ops_strip")
  if not (strip and strip.say) then return end
  told = true
  save.set("medical.told", true)
  local bf = ref("base_facilities")
  local s = bf and bf.medicalSite
  local where = (s and s.where) or "between the Research Lab and the VAB"
  local how = (s and s.link == false) and "Drive in off the road, or walk in its west door." or "Walk through from the lab's east door, or drive in up the alley off Road West."
  pcall(strip.say, string.format("The Medical Bay is open %s. %s Dr Imke Rao takes the rescues and patches up anyone who walks in.",
    where, how), "Ops")
  if s and s.blockedBy then say_log("stands off its first lot: " .. tostring(s.blockedBy) .. " is there") end
end

function update(node, dt)
  ROOT = node
  if not body_name and node.parent and node.parent.name then body_name = node.parent.name end
  if not F then F = frame_of(node) end
  t_born = t_born or now()
  if not (valid(interior) and floor_c) then
    if now() - look_t < 0.5 then return end
    look_t = now()
    interior = find_tagged_near("med_interior")
    link = find_tagged_near("med_link")
    linked = valid(link)
    local fm = child(ROOT, "Bay Floor")
    if fm then floor_c = { x = fm.x, y = fm.y, z = fm.z } end
    -- the prefab origin in the ground frame: the Bay Floor marker's ground
    -- point is (2.75, 0.12, 2.6) (tools/base_buildings.py MED markers)
    if fm then origin_g = { x = 2.75 - fm.x, y = 0.12 - fm.y, z = 2.6 - fm.z } end
    if not valid(interior) then return end
    inside = true
    set_inside(false)
  end
  if not linked and now() - look_t > 2 then
    look_t = now()
    link = find_tagged_near("med_link")
    linked = valid(link)
  end
  if not provider_on then
    local reg = ref("context_registry")
    if reg and reg.register then reg.register("prop", provider, { id = "medical_medic", order = 3 }); provider_on = true end
  end
  local b = space.body(body_name)
  if not b then return end
  spawn_medic()
  local a = find and find("Astronaut")
  local cam = find and (find("Camera 1") or find("Camera"))
  local p = valid(a) and a or cam
  local d = 1e9
  if valid(p) then d = len(p.x - (b.x + F.o.x), p.y - (b.y + F.o.y), p.z - (b.z + F.o.z)) end
  local near = params.near or 60
  set_inside(forceInside or d < (inside and near + 10 or near))
  tell_once()
  -- the talk: walked off, the builder up, Esc
  if talking and reshot then
    local pc = ref("planet_camera")
    if pc and not pc.cinematic and pc.setShot then reshot = false; pc.setShot(talk_shot(), 0.7) end
  end
  if talking then
    local gm = ref("game_manager")
    local mw = valid(medic) and medic.worldPos
    local dm = (valid(a) and mw) and len(a.x - mw.x, a.y - mw.y, a.z - mw.z) or 1e9
    if dm > (params.leave or 5.5) then end_talk("walked off")
    elseif gm and gm.inputOwner == "builder" then end_talk("builder")
    elseif input and input.pressed and input.pressed("escape") then
      local run = ref("scenario_run")
      local _, ch = nil, nil
      if run and run.careerLine then _, ch = run.careerLine() end
      if not ch then end_talk("esc") end
    end
  end
  -- the bay floor and the survivors (4 Hz, the crew within 300 m)
  bay_t = bay_t + (dt or 0)
  if bay_t >= 0.25 and d < 300 then
    bay_t = 0
    local seen = nil
    for _, v in ipairs((findScripts and findScripts("vessel_controller")) or {}) do
      if v.node and valid(v.node) and not (v.isLost and v.isLost()) and inBay(v.node.x, v.node.y, v.node.z) then
        seen = v.craftName or "craft"
      end
    end
    if seen and not (craftIn and craftIn.name == seen) then say_log("craft in the bay: " .. tostring(seen)) end
    craftIn = seen and { name = seen, t = (craftIn and craftIn.name == seen) and craftIn.t or now() } or nil
    local C = ref("crew")
    if C and C.clients then
      for _, r in ipairs(C.clients()) do
        if r.status ~= "dead" and not isAdmitted(r.id) then
          local x, y, z, how = survivor_at(C, r)
          if x and (inRoom(x, y, z) or inBay(x, y, z)) then admit(r.id, how) end
        end
      end
    end
  end
end

function lateUpdate(node, dt)
  if talking or admit_talk then portrait_place() end
end
