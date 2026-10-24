-- BUILDER_HISTORY — the builder's command history (WP1, docs/builder-design.md
-- §8.4). A pure RULEBOOK script: no scene access, its globals are its API,
-- and it loads from disk in a luajit test. Reach it with
-- findScript("builder_history").
--
-- An ENTRY is { label, undo = fn, redo = fn, merge = key|nil, close = fn|nil }.
-- The builder makes undo/redo from before/after snapshots of the parts an
-- edit touched, so an entry is always reversible both ways.
--
--   H = newHistory(cap)            cap default 500
--   H:push(e)                      a new step: the redo tail is dropped. When
--                                  e.merge equals the open step's merge key the
--                                  two become one step (a drag, a slider):
--                                  the old step is kept (its redo too, unless
--                                  e.replaceRedo); the label becomes e's
--   H:seal()                       close the open step (the next push with the
--                                  same key starts a new step)
--   H:undo() / H:redo() → the entry, or nil
--   H:canUndo() / H:canRedo()
--   H:list() → { items = { label… }, index = n }  (n = steps applied)
--   H:jump(i)                      undo/redo until i steps are applied
--   H:clear()  H:top()  H:size()

function newHistory(cap)
  local H = { cap = cap or 500, items = {}, index = 0, open = nil }

  function H:push(e)
    -- a merge into the open step
    if e.merge and self.open and self.open == e.merge and self.index == #self.items and self.index > 0 then
      local top = self.items[self.index]
      -- the open step keeps its undo; its redo is replaced only when the new
      -- entry asks (an entry that takes its AFTER lazily keeps its own)
      if e.replaceRedo then top.redo = e.redo end
      top.label = e.label or top.label
      return top
    end
    for i = #self.items, self.index + 1, -1 do self.items[i] = nil end
    self.items[#self.items + 1] = e
    while #self.items > self.cap do table.remove(self.items, 1) end
    self.index = #self.items
    self.open = e.merge
    return e
  end

  function H:seal() self.open = nil end

  function H:undo()
    self.open = nil
    if self.index <= 0 then return nil end
    local e = self.items[self.index]
    self.index = self.index - 1
    if e.undo then e.undo() end
    return e
  end

  function H:redo()
    self.open = nil
    if self.index >= #self.items then return nil end
    self.index = self.index + 1
    local e = self.items[self.index]
    if e.redo then e.redo() end
    return e
  end

  function H:canUndo() return self.index > 0 end
  function H:canRedo() return self.index < #self.items end
  function H:top() return self.items[self.index] end
  function H:size() return #self.items end

  function H:list()
    local out = {}
    for i, e in ipairs(self.items) do out[i] = e.label or "edit" end
    return { items = out, index = self.index }
  end

  function H:jump(i)
    i = math.max(0, math.min(#self.items, math.floor(i or 0)))
    while self.index > i do self:undo() end
    while self.index < i do self:redo() end
    return self.index
  end

  function H:clear() self.items, self.index, self.open = {}, 0, nil end

  return H
end
