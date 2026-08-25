--- Pane: interactive, navigable list of notes.
--
-- The primary/focused pane of the note-list window. Owns the "current
-- selection" and publishes the selected note to `ctx.state.note` so sibling
-- panes (`note_preview`, `file_preview`) can show it — this pane must be
-- listed first among the window's `panes` (see `noteit.ui.handler.open`) so
-- its `render` runs, and updates `ctx.state.note`, before its siblings'.
--
-- Expects `ctx.opts` to provide:
--   `notes()`: function returning the current array of notes to display.
--   `relative_filename(filename)`: function formatting a note's filename.
-- Expects `ctx.dispatch` to have the following actions registered:
--   `goto_note(note)`: open the note's source file at its line.
--   `delete_note(note)`: remove the note (assumed to trigger a re-render,
--   e.g. via the caller's own change-notification plumbing).
-- @module noteit.ui.panes.note_list
local M = {}

M.style = {
  title = "Note List",
}

--- Move the selection by `delta` rows, clamped to the note list's bounds.
-- @local
local function move_selection(ctx, delta)
  local notes = ctx.opts.notes()
  if #notes == 0 then
    return
  end

  local current = ctx.state.selected_index or 1
  ctx.state.selected_index = math.max(1, math.min(current + delta, #notes))
  ctx.render()
end

--- Register the list's navigation and action keymaps.
-- @param ctx table see `noteit.ui.handler`'s `ctx` documentation
function M.setup(ctx)
  for _, key in ipairs({ "j", "<Down>", "<Tab>" }) do
    ctx.map("n", key, function()
      move_selection(ctx, 1)
    end)
  end

  for _, key in ipairs({ "k", "<Up>", "<S-Tab>" }) do
    ctx.map("n", key, function()
      move_selection(ctx, -1)
    end)
  end

  ctx.map("n", "<CR>", function()
    local note = ctx.state.note
    if not note then
      return
    end
    ctx.close()
    ctx.dispatch("goto_note", note)
  end)

  ctx.map("n", "dd", function()
    local note = ctx.state.note
    if note then
      ctx.dispatch("delete_note", note)
    end
  end)

  ctx.map({ "n", "i" }, "<Esc>", function()
    ctx.close()
  end)
end

--- Render the note list and publish the selected note to `ctx.state.note`.
-- Closes the whole window if no notes remain (e.g. the last one was just
-- deleted).
-- @param ctx table see `noteit.ui.handler`'s `ctx` documentation
-- @return boolean|nil `false` if this (and the whole window) got closed
function M.render(ctx)
  local notes = ctx.opts.notes()

  if #notes == 0 then
    vim.notify("No notes available", vim.log.levels.WARN)
    ctx.close()
    return false
  end

  local selected_index = math.max(1, math.min(ctx.state.selected_index or 1, #notes))
  ctx.state.selected_index = selected_index
  ctx.state.note = notes[selected_index]

  local lines, highlights = {}, {}
  for i, note in ipairs(notes) do
    lines[i] = string.format("%d. %s:%d", i, ctx.opts.relative_filename(note.filename), note.lnum)
    highlights[#highlights + 1] = {
      group = "Bold",
      line = i - 1,
      col_start = 0,
      col_end = #tostring(i) + 1,
    }
  end
  highlights[#highlights + 1] = { group = "Visual", line = selected_index - 1 }

  ctx.set_lines(lines, {
    readonly = true,
    namespace = ctx.opts.ui_namespace,
    highlights = highlights,
  })

  return true
end

return M
