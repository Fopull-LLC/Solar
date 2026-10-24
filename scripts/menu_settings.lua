-- The main menu's SETTINGS page (on the "Settings Panel" node). The same rows
-- the pause menu shows — settings.lua describes them once — inside the
-- menu's own frame, swapped in for the title page the way the New Galaxy panel
-- is: exactly one panel visible, so it is a page turn, not an overlay.
--
-- The SETTINGS button (menu_ng_button, role "settings") calls openPanel; Esc
-- or Back goes back to the title page.

open = false   -- published: menu_newsave and the slot buttons leave Esc alone while up

local el
local refs = {}
local function ref(kind)
  local r = refs[kind]
  if not r or not r.valid then r = findScript(kind); refs[kind] = r end
  return r
end

local W = 580

local function show(on)
  open = on
  if el then el.visible = on end
  local main = find("Menu Panel")
  local m = main and main:getcomponent("UiElement")
  if m then m.visible = not on end
end

function openPanel() show(true) end

function closePanel()
  local st = ref("settings")
  if st and st.flush then st.flush() end
  show(false)
end

local function describe()
  local st = ref("settings")
  local rows = {
    { "text", key = "title", style = "panel/heading", w = "100%", h = "fit", text = "SETTINGS" },
    { "box", key = "rule", style = "panel/rule", w = "100%", h = 1 },
  }
  if st and st.rows then
    for _, r in ipairs(st.rows(W)) do rows[#rows + 1] = r end
  else
    rows[#rows + 1] = { "text", key = "na", style = "panel/body", w = "100%", h = "fit",
                        text = "Settings are not available in this scene." }
  end
  rows[#rows + 1] = { "box", key = "rule2", style = "panel/rule", w = "100%", h = 1 }
  rows[#rows + 1] = { "row", key = "foot", w = "100%", h = "fit", gap = 12, pad = 0, align = "center",
    items = {
      { "button", key = "back", style = "panel/secondary", w = 120, h = 32, textAlign = "center",
        text = "Back", onClicked = function()
          local fx = ref("sfx"); if fx then fx.play("close") end
          closePanel()
        end },
      { "text", key = "hint", style = "panel/hint", w = "grow", h = "fit", text = "Esc goes back." },
    }, function(x) return x end }
  return { "col", key = "settings", style = "panel/frame", w = "100%", dir = "col", gap = 8,
           pad = 18, align = "start", items = rows, function(r) return r end }
end

-- (No font primer: a font named only by a style is loaded since 0.117.0-rc7,
-- floptle/0477. Until rc6 one hidden element per face named it.)

function start(node)
  el = node:getcomponent("UiElement")
  show(false)
end

function update(node, dt)
  if not open then return end
  local st = ref("settings")
  if input.pressed("escape") and not (st and st.rebinding and st.rebinding()) then
    local fx = ref("sfx"); if fx then fx.play("close") end
    closePanel()
    return
  end
  if el and el.width ~= W then el.width = W end
  ui.make(node, { describe() })
end
