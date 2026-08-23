--- Floating note editor with optional source-file preview.
-- @module noteit.ui.note_editor
local floating = require("noteit.ui.floating")

local M = {}
local note_buffer_savers = {}

--- Render a source-file preview and highlight the note's line with an extmark.
-- @param pane table the preview pane, as returned by `floating.open`
-- @param filename string the file to preview
-- @param lnum number the note's line number
-- @param spec table the pane layout spec, used for `spec.height`
-- @param top_padding number lines to keep above the target line
-- @param file_lines table|nil pre-read file lines, to avoid re-reading the file
-- @param ui_namespace number the extmark namespace used for the line highlight
function M.render_file_preview(pane, filename, lnum, spec, top_padding, file_lines, ui_namespace)
  if file_lines == nil then
    local ok, lines = pcall(vim.fn.readfile, filename)
    file_lines = ok and lines or nil
  end

  floating.update(pane, spec)

  if not file_lines then
    floating.render(pane, { "[unable to load preview for " .. filename .. "]" }, { readonly = true })
    return
  end

  floating.render(pane, file_lines, {
    readonly = true,
    filetype = vim.filetype.match({ filename = filename }) or "text",
  })

  local line_count = #file_lines
  local target_line = math.max(1, math.min(lnum or 1, line_count))

  vim.wo[pane.win].number = true
  vim.wo[pane.win].scrolloff = top_padding or 0

  vim.api.nvim_buf_clear_namespace(pane.buf, ui_namespace, 0, -1)
  vim.api.nvim_buf_set_extmark(pane.buf, ui_namespace, target_line - 1, 0, {
    line_hl_group = "Visual",
  })

  vim.api.nvim_win_set_cursor(pane.win, { target_line, 0 })
  vim.api.nvim_win_call(pane.win, function()
    vim.cmd("normal! zz")
  end)
end

--- Convert a note's text into the fixed-height lines shown in the list.
-- @param note table the note whose text should be rendered
-- @param max_height number the fixed number of lines to return
-- @return table the note's text, split into `max_height` lines
function M.build_note_preview(note, max_height)
  local text = (note and note.note) or ""
  local lines = vim.split(text, "\n", { plain = true, trimempty = false })

  if #lines == 0 then
    lines = { "[empty note]" }
  end

  local height = math.max(1, math.min(max_height or #lines, #lines))
  local preview_lines = {}
  for i = 1, height do
    preview_lines[#preview_lines + 1] = lines[i]
  end

  while #preview_lines < (max_height or #preview_lines) do
    preview_lines[#preview_lines + 1] = ""
  end

  return preview_lines
end

--- Open a floating note editor and optionally pair it with a source preview.
-- @param initial_text string|nil the text to prefill the editor with
-- @param opts table `config`, `preview`, `ui_namespace`, and `on_submit`
function M.open(initial_text, opts)
  local preview_top_padding = vim.wo.scrolloff
  local layout = floating.editor_layout(
    opts.config.window_style,
    opts.config.preview_split_ratio,
    opts.config.file_preview and opts.preview and opts.preview.filename
  )
  local panes = {}

  if layout.preview then
    panes.preview = floating.open(vim.tbl_extend("force", layout.preview, {
      enter = false,
      focusable = false,
    }))
    M.render_file_preview(
      panes.preview,
      opts.preview.filename,
      opts.preview.lnum,
      layout.preview,
      preview_top_padding,
      nil,
      opts.ui_namespace
    )
  end

  panes.editor = floating.open(layout.editor)
  local float_buf, float_win = panes.editor.buf, panes.editor.win

  local closing_pair = false
  --- Close the editor and its optional preview exactly once.
  -- @local
  local function close_note_pair()
    if closing_pair then
      return
    end

    closing_pair = true
    floating.close(panes)
  end

  vim.api.nvim_buf_set_name(
    float_buf,
    string.format("noteit://%s/%d", vim.fn.sha256(tostring(vim.loop.hrtime())), float_buf)
  )

  vim.bo[float_buf].buftype = "acwrite"
  vim.bo[float_buf].bufhidden = "wipe"
  vim.bo[float_buf].swapfile = false

  if initial_text then
    vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { initial_text })
    vim.api.nvim_win_set_cursor(float_win, { 1, #initial_text })
    vim.bo[float_buf].modified = false
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = float_buf,
    once = true,
    callback = function()
      note_buffer_savers[float_buf] = nil
      close_note_pair()
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = float_buf,
    once = true,
    callback = close_note_pair,
  })

  if panes.preview then
    vim.api.nvim_create_autocmd("BufWinLeave", {
      buffer = panes.preview.buf,
      once = true,
      callback = close_note_pair,
    })
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = float_buf,
    once = true,
    callback = function()
      vim.bo[float_buf].modified = false
      M.save(float_buf)
    end,
  })

  local submitted = false
  --- Submit the editor contents once and close all editor panes.
  -- @param text string the submitted note text
  -- @local
  local function finish(text)
    if submitted then
      return
    end

    submitted = true
    note_buffer_savers[float_buf] = nil
    floating.close(panes)
    opts.on_submit(text)
  end

  note_buffer_savers[float_buf] = function()
    local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    local text = table.concat(lines, " "):gsub("^%s*(.-)%s*$", "%1")
    finish(text)
  end

  vim.api.nvim_buf_create_user_command(float_buf, "SaveNote", function()
    M.save(float_buf)
  end, {})
end

--- Submit a registered note-editor buffer.
-- @param bufnr number|nil the note-editor buffer; defaults to the current buffer
function M.save(bufnr)
  local target_buf = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(target_buf) then
    vim.notify("Noteit: invalid buffer", vim.log.levels.WARN)
    return
  end

  local save = note_buffer_savers[target_buf]
  if type(save) ~= "function" then
    vim.notify("Noteit: SaveNote is only available in note buffers", vim.log.levels.WARN)
    return
  end

  save()
end

--- Open a note's source file and move the cursor to its recorded line.
-- @param note table the note to navigate to
function M.goto_note(note)
  if not note or not note.filename or note.filename == "" then
    return
  end

  vim.cmd("edit " .. vim.fn.fnameescape(note.filename))

  if note.lnum and note.lnum > 0 then
    local line_count = vim.api.nvim_buf_line_count(0)
    local target_line = math.min(note.lnum, line_count)
    vim.api.nvim_win_set_cursor(0, { target_line, 0 })
    vim.cmd("normal! zv")
  end
end

return M
