-- MISSION STORY — the career contracts' people and their lines, as DATA
-- (missions plan S0 §2.0, "Career story beats"; Ty 2026-11-11: story in the
-- career missions — named people, dialogue, immersive moments, few popups).
--
-- Each contract kind belongs to a FAMILY; each family names its cast (the
-- client's dispatcher, the survivor…) and, per event, a few VARIANTS — each a
-- short beat list for scenario_run.runBeats (a career run: say, choice, shot,
-- wait, sound, weather, wear …; nothing a scenario's goals drive). The
-- contract's id picks the variant and the client company, so a contract
-- keeps its voice for its whole life.
--
--   beatsFor(m | contract id | family, event, extra) → beats, cast | nil
--   companyOf(m) → name      dispatcherOf(company) → name
--
-- Events the game fires: accept (signed), delivered (paid), failed
-- (abandoned or lost), and for the rescue families near, contact, carried,
-- admitted (the Medical Bay took them in; medical.lua adds Dr Rao's line).
-- Substitutions: {name} (the survivor), {company}, {dispatcher}, {body},
-- {title}. Radio voices (cast `radio`) go to the Ops strip; a `link` makes
-- them garble with no comms path. One choice per mission at most, at
-- contact; everything else is the strip, never a panel (few popups).
--
-- Pure: no engine calls; missions.lua and medical.lua call it through
-- findScript("mission_story") (it rides ScenarioLib); tests load it alone.

COMPANIES = { "Barrow Survey Co-op", "Teller & Voss Prospecting", "Halvorsen Orbital", "Sable Line Freight",
              "Meridian Caving Club", "Kestrel Relay", "Okonkwo Logistics", "Ridgeway Alpine" }
DISPATCHERS = {
  ["Barrow Survey Co-op"] = "Ines Barrow", ["Teller & Voss Prospecting"] = "Marta Voss",
  ["Halvorsen Orbital"] = "Kjell Halvorsen", ["Sable Line Freight"] = "Dez Okafor-Sable",
  ["Meridian Caving Club"] = "Pip Achterberg", ["Kestrel Relay"] = "Yuna Kestrel",
  ["Okonkwo Logistics"] = "Chidi Okonkwo", ["Ridgeway Alpine"] = "Saoirse Ridgeway",
}
-- which family a contract kind's story is
FAMILY_OF = {
  order = "buyer", bulk = "buyer", supply = "buyer", pipeline = "buyer",
  survey = "survey", layer = "survey",
  soi = "flight", orbit = "flight", land = "flight", flag = "flight", haul = "flight", orehaul = "flight",
  cargo = "flight", establish = "flight", logger = "flight",
  rescue = "rescue", rescue_rover = "rescue", rescue_cave = "rescue_cave", rescue_peak = "rescue_peak",
}

local function S(who, text) return { say = { who = who, text = text } } end

STORY = {
  -- a buyer of ore, timber or freight: their dispatcher on the radio
  buyer = {
    cast = { client = { name = "{dispatcher}", tag = "{company}", radio = true } },
    on = {
      accept = {
        { S("client", "{company} here. We'll take it at the depot. Don't send me rocks with mud in them.") },
        { S("client", "Signed and logged. {dispatcher} at {company}. The truck's waiting on you, no rush. Some rush.") },
        { S("client", "Good. Our crusher's been idle two days. Bring it in when you can.") },
      },
      delivered = {
        { S("client", "Weighed and booked. Money's on its way. Pleasure doing business.") },
        { S("client", "That's the lot. Clean load, too. We'll ask for you again.") },
        { S("client", "Got it. {dispatcher} out.") },
      },
      failed = {
        { S("client", "We'll find someone else. {company} out.") },
      },
    },
  },
  -- a survey drive: the client wants ground covered and the numbers
  survey = {
    cast = { client = { name = "{dispatcher}", tag = "{company}", radio = true } },
    on = {
      accept = {
        { S("client", "Drive it, log it, bring the rover home. Our charts of that ground are guesses.") },
        { S("client", "{company}. We need eyes on that stretch before our crews go out. Thanks for taking it.") },
      },
      delivered = {
        { S("client", "Logs are in. That ridge is not where the old map put it. Good work.") },
        { S("client", "Survey received. Our people can go out there now without guessing.") },
      },
      failed = { { S("client", "Understood. We'll wait for the next window.") } },
    },
  },
  -- a flight contract: Mission Control's own voice
  flight = {
    cast = {},
    on = {
      accept = {
        { S("ops", "Contract's on the board as signed. Build what it needs; we'll be on the loop.") },
        { S("ops", "Signed. The advance is in the account. Fly it clean.") },
      },
      delivered = {
        { S("ops", "That's the contract. Nicely flown.") },
        { S("ops", "Client confirms. Paid in full. Good flying.") },
      },
      failed = { { S("ops", "Contract withdrawn. It happens. Pick another off the board.") } },
    },
  },
  -- a rescue: the client's dispatcher, and the survivor's own suit radio
  -- (garbled out of line of sight)
  rescue = {
    cast = { dispatch = { name = "{dispatcher}", tag = "{company}", radio = true },
             survivor = { name = "{name}", tag = "SURVIVOR", radio = true, link = "crew:{name}" } },
    on = {
      accept = {
        { S("dispatch", "This is {dispatcher}, {company}. {name}'s rover is dead out there and their suit won't last forever. Please hurry."),
          S("ops", "Medical Bay's warned. Bring them home.") },
        { S("dispatch", "{company} dispatch. We lost the carrier on {name}'s rover an hour ago. They're not answering on the main channel."),
          S("ops", "Take a second seat, and a Repair Kit if you want the rover back.") },
      },
      near = {
        { S("survivor", "Is that— I can see your lights. Oh thank god. I'm by the rover.") },
        { S("survivor", "Hello? Hello, I hear a motor. I'm here, I'm here.") },
      },
      contact = {
        { S("survivor", "My leg. I can't put weight on it. I'm sorry, I'm so sorry about this."),
          { choice = { who = "survivor", prompt = "What do we do?", options = {
              { text = "Let me look at it first", var = { treat = true } },
              { text = "No time. I'm carrying you", var = { treat = false } } } } } },
      },
      carried = {
        { S("survivor", "Okay. Okay. Mind the— ow. Okay.") },
        { S("survivor", "I've got the helmet light. You watch the ground.") },
      },
      delivered = {
        { S("dispatch", "We heard. {name}'s in the Medical Bay. Thank you. I mean that."),
          S("ops", "Client's paid. Good work out there.") },
      },
      admitted = {
        { S("survivor", "Thank you. I didn't think anyone was coming.") },
      },
      failed = {
        { S("dispatch", "...We'll send someone to bring {name} home.") },
      },
    },
  },
}
STORY.rescue_cave = STORY.rescue
STORY.rescue_peak = STORY.rescue

-- ── pure helpers ────────────────────────────────────────────────────────────
local function hash(s)
  local h = 5381
  s = tostring(s or "")
  for i = 1, #s do h = (h * 33 + s:byte(i)) % 2147483647 end
  return h
end
hashOf = hash
function companyOf(m)
  if type(m) == "table" and type(m.company) == "string" then return m.company end
  local id = type(m) == "table" and (m.id or m.title) or m
  return COMPANIES[1 + hash(id) % #COMPANIES]
end
function dispatcherOf(company) return DISPATCHERS[company] or "the dispatcher" end
local function fill(s, t)
  return (tostring(s):gsub("{(%w+)}", function(k) return t[k] ~= nil and tostring(t[k]) or ("{" .. k .. "}") end))
end
-- a deep copy with every string filled in
local function filled(v, t)
  if type(v) == "string" then return fill(v, t) end
  if type(v) ~= "table" then return v end
  local o = {}
  for k, x in pairs(v) do o[k] = filled(x, t) end
  return o
end
-- (pure) the family a contract (or a kind, or a family name) belongs to
function familyOf(m)
  if type(m) == "string" then
    if STORY[m] then return m end
    return FAMILY_OF[m]
  end
  if type(m) ~= "table" then return nil end
  return m.story or FAMILY_OF[m.kind or ""] or (m.gen and "flight") or nil
end
-- THE LINES: (m | family | kind, event, extra) → beats, cast | nil.
-- `m` may also be a contract id when `byId` (missions.byId) is given in extra.
function beatsFor(m, event, extra)
  extra = extra or {}
  if type(m) == "string" and not familyOf(m) and extra.byId then m = extra.byId(m) or m end
  local fam = familyOf(m)
  local st = fam and STORY[fam]
  local list = st and st.on[event]
  if not (list and #list > 0) then return nil end
  local key = type(m) == "table" and (m.id or m.title) or m
  local company = extra.company or companyOf(m)
  local t = { company = company, dispatcher = dispatcherOf(company), name = extra.name or (type(m) == "table" and m.who) or "them",
              body = extra.body or (type(m) == "table" and m.body) or "here", title = type(m) == "table" and m.title or "" }
  local variant = list[1 + hash(tostring(key) .. ":" .. event) % #list]
  return filled(variant, t), filled(st.cast or {}, t)
end
