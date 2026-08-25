--- Pane: writable buffer for creating or editing a note's text.
--
-- The primary/focused pane of the note editor window. Publishes the note's
-- source location to `ctx.state.note` (once, in `setup`) so a sibling
-- `file_preview` pane, if configured for this window, can show it — this
-- pane must be listed first among the window's `panes` (see
-- `noteit.ui.handler.open`) so `setup` runs before the sibling's first
-- render.
--
-- Expects `ctx.opts` to provide:
--   `initial_text` (string|nil): text to prefill the buffer with.
--   `preview` (table|nil): `{ filename, lnum }` for the sibling file preview.
-- Expects `ctx.dispatch` to have the `submit_note(text)` action registered,
-- called with the buffer's trimmed contents on `:write`.
-- @module noteit.ui.panes.note_editor
local M = {}

M.style = {
  title = "Note",
}

--- Build a unique scratch buffer name; required for `buftype = "acwrite"`.
-- @local
local function unique_buffer_name(buf)
  return string.format("noteit://%s/%d", vim.fn.sha256(tostring(vim.loop.hrtime())), buf)
end

--- Prepare the editor buffer: options, initial text, and the write handler.
-- @param ctx table see `noteit.ui.handler`'s `ctx` documentation
function M.setup(ctx)
  vim.api.nvim_buf_set_name(ctx.buf, unique_buffer_name(ctx.buf))
  vim.bo[ctx.buf].buftype = "acwrite"
  vim.bo[ctx.buf].bufhidden = "wipe"
  vim.bo[ctx.buf].swapfile = false

  ctx.state.note = ctx.opts.preview

  local initial_text = ctx.opts.initial_text
  if initial_text then
    local initial_lines = vim.split(initial_text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(ctx.buf, 0, -1, false, initial_lines)
    vim.api.nvim_win_set_cursor(ctx.win, { #initial_lines, #initial_lines[#initial_lines] })
    vim.bo[ctx.buf].modified = false
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = ctx.buf,
    once = true,
    callback = function()
      vim.bo[ctx.buf].modified = false
      local lines = vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false)
      local text = table.concat(lines, "\n"):gsub("^%s*(.-)%s*$", "%1")
      ctx.dispatch("submit_note", text)
    end,
  })
end

return M
