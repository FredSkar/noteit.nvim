--- Pane: read-only preview of a note's own text.
--
-- Reads `ctx.state.note` (set by the sibling `note_list` pane) and shows its
-- `.note` text, padded/truncated to this pane's own window height so the
-- layout never jiggles as the selection changes. Hides itself (returns
-- `false`) when no note is selected.
-- @module noteit.ui.panes.note_preview
local M = {}

M.style = {
  title = "Note Preview",
  focusable = false,
}

--- Render the selected note's text, or ask the handler to hide this pane.
-- @param ctx table see `noteit.ui.handler`'s `ctx` documentation
-- @return boolean|nil `false` to hide this pane; anything else keeps it shown
function M.render(ctx)
  local note = ctx.state.note
  if not note then
    return false
  end

  local text_lines = vim.split(note.note or "", "\n", { plain = true, trimempty = false })
  if #text_lines == 0 then
    text_lines = { "[empty note]" }
  end

  local height = vim.api.nvim_win_get_height(ctx.win)
  local lines = {}
  for i = 1, height do
    lines[i] = text_lines[i] or ""
  end

  ctx.set_lines(lines, {
    readonly = true,
    filetype = "text",
    wrap = true,
    linebreak = true,
    breakindent = true,
  })

  return true
end

return M
