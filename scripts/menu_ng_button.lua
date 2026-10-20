-- A menu button that forwards its click to menu_newsave's press(role)
-- router. role: "create" / "cancel" / "seed" (the seed field — clicking
-- clears back to random), or "quit" / "settings" on the title page. Hover and press looks
-- come from the button's style (ui/solar.uistyle.ron, "menu/...").

defaults = { role = "cancel" }

function clicked(node)
  local fx = findScript("sfx")
  if fx then fx.play("click") end
  if params.role == "quit" then
    app.quit()
    return
  end
  if params.role == "settings" then
    local ms = findScript("menu_settings")
    if ms and ms.openPanel then ms.openPanel() end
    return
  end
  local mgr = findScript("menu_newsave")
  if mgr then mgr.press(params.role) end
end
