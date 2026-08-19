local floating = require("noteit.ui.floating")

local M = {}
local note_buffer_savers = {}

local function build_file_preview(filename, lnum, max_height, top_padding, file_lines)
  local ok = true
  if file_lines == nil then
    ok, file_lines = pcall(vim.fn.readfile, filename)
  end

  if not ok or type(file_lines) ~= "table" or #file_lines == 0 then
    return { "[unable to load preview for " .. filename .. "]" }, 1
  end

  local line_count = #file_lines
  local target_line = math.max(1, math.min(lnum or 1, line_count))
  local visible_height = math.max(1, math.min(max_height or line_count, line_count))
  local lines_before = math.min(math.max(0, top_padding or 0), visible_height - 1)
  local lines_after = visible_height - 1 - lines_before
  local start_line = target_line - lines_before
  local end_line = target_line + lines_after

  if start_line < 1 then
    end_line = math.min(line_count, end_line + (1 - start_line))
    start_line = 1
  end

  if end_line > line_count then
    start_line = math.max(1, start_line - (end_line - line_count))
    end_line = line_count
  end

  local lines = {}
  for i = start_line, end_line do
    lines[#lines + 1] = string.format("%4d │ %s", i, file_lines[i] or "")
  end

  return lines, target_line - start_line + 1
end

function M.render_file_preview(pane, filename, lnum, spec, top_padding, file_lines, ui_namespace)
  local lines, highlight_row = build_file_preview(filename, lnum, spec.height, top_padding, file_lines)
  floating.update(pane, spec)
  floating.render(pane, lines, {
    readonly = true,
    filetype = vim.filetype.match({ filename = filename }) or "text",
    namespace = ui_namespace,
    highlights = {
      { group = "Visual", line = highlight_row - 1 },
    },
  })
end

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
