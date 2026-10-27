-- A menu button that forwards its click to menu_newsave's press(role)
-- router. role: "create" / "cancel" / "seed" (the seed field — clicking
-- clears back to random), or "quit" / "settings" on the title page. Hover and press looks
-- come from the button's style (ui/solar.uistyle.ron, "menu/...").

defaults = { role = "cancel" }

function clicked(node)
  local fx = findScript("sfx")
  if fx then fx.play("click") end
  if params.role == "quit" then
    -- Save, THEN leave (playtest 2026-10-27: "the Quit button does nothing").
    -- The title page has no world to checkpoint, but the settings and the
    -- slots' last writes may still be on the writer thread: wait for them to
    -- land, then quit. app.quit() closes an exported build (and stops Play
    -- in the editor, ends a `floptle run`); it also flushes, this is belt and
    -- braces for a build that may not get the chance (engine card 0564).
    if save and save.flush then pcall(save.flush, { wait = true }) end
    if app and app.quit then app.quit() end
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
