--- Pane: read-only preview of a note's source file, centered on its line.
--
-- Reads `ctx.state.note` (a `{ filename, lnum }`-shaped table set by a
-- sibling pane — `note_list` for the note-list window, `note_editor` for the
-- editor window) and shows that file with the note's line highlighted.
-- Hides itself (returns `false`) whenever there's no note or no filename.
-- @module noteit.ui.panes.file_preview
local M = {}

M.style = {
  title = "File Preview",
  focusable = false,
}

--- Read a file's lines, tolerating files that can't be read.
-- @local
local function read_lines(filename)
  local ok, lines = pcall(vim.fn.readfile, filename)
  return ok and lines or nil
end

--- Render the previewed file, or ask the handler to hide this pane.
-- @param ctx table see `noteit.ui.handler`'s `ctx` documentation. Expects
-- `ctx.opts.ui_namespace` (extmark namespace) and `ctx.opts.top_padding`
-- (scrolloff to keep above the highlighted line, usually the user's own
-- `'scrolloff'` from before the window opened).
-- @return boolean|nil `false` to hide this pane; anything else keeps it shown
function M.render(ctx)
  local note = ctx.state.note
  if not note or not note.filename or note.filename == "" then
    return false
  end

  local lines = read_lines(note.filename)
  if not lines then
    ctx.set_lines({ "[unable to load preview for " .. note.filename .. "]" }, { readonly = true })
    return true
  end

  ctx.set_lines(lines, {
    readonly = true,
    filetype = vim.filetype.match({ filename = note.filename }) or "text",
  })

  local target_line = math.max(1, math.min(note.lnum or 1, #lines))

  vim.wo[ctx.win].number = true
  vim.wo[ctx.win].scrolloff = ctx.opts.top_padding or 0

  vim.api.nvim_buf_clear_namespace(ctx.buf, ctx.opts.ui_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(ctx.buf, ctx.opts.ui_namespace, target_line - 1, 0, {
    line_hl_group = "Visual",
  })

  vim.api.nvim_win_set_cursor(ctx.win, { target_line, 0 })
  vim.api.nvim_win_call(ctx.win, function()
    vim.cmd("normal! zz")
  end)

  return true
end

return M
