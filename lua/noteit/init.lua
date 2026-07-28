local M = {}
local floating = require("noteit.ui.floating")
local note_list = require("noteit.ui.note_list")

-- Namespace for virtual text as the directory where nvim was launched.
local path_hash = vim.fn.sha256(vim.fn.getcwd()):sub(1, 16)
local note_namespace = vim.api.nvim_create_namespace(path_hash)
local ui_namespace = vim.api.nvim_create_namespace(path_hash .. "_ui")
local augroup = vim.api.nvim_create_augroup("notes_" .. path_hash, { clear = true })

local defaults = {
  symbol = "🔖",
  highlight = "Todo",
  notes_file = vim.fn.stdpath("data") .. "/noteit/" .. path_hash .. ".json",
  file_preview = true,
  list_note_preview = true,
  preview_split_ratio = 0.6,

  window_style = {
    width = 0.8,
    height = 0.8,
    spacing = {
      horizontal = 2,
      vertical = 2,
    },
  },
}
M.config = vim.deepcopy(defaults)

-- Table to store notes
M.notes = {}
local note_buffer_savers = {}
local autocmds_registered = false
local active_note_list

local function refresh_active_note_list()
  if active_note_list then
    active_note_list.refresh()
  end
end

local function selected_list_note()
  if active_note_list and active_note_list.is_focused() then
    return active_note_list.selected_note()
  end
end

local function place_note(buf, note)
  local opts = {
    virt_text = { { M.config.symbol, M.config.highlight } },
    virt_text_pos = "eol",
  }

  if note.note_id then
    opts.id = note.note_id
  end

  local note_id = vim.api.nvim_buf_set_extmark(buf, note_namespace, note.lnum - 1, 0, opts)
  note.note_id = note_id
end

-------------------------------------------------------------
--- Sync notes with buffer lines when file is edited
-------------------------------------------------------------
local function sync_notes_for_buf(buf)
  local filename = vim.api.nvim_buf_get_name(buf)
  if filename == "" then
    return
  end

  for _, note in ipairs(M.notes) do
    if note.filename == filename and note.note_id then
      local pos = vim.api.nvim_buf_get_extmark_by_id(buf, note_namespace, note.note_id, {})
      if pos and #pos > 0 then
        note.lnum = pos[1] + 1
      end
    end
  end
end

local function sync_all_loaded_notes()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      sync_notes_for_buf(buf)
    end
  end
end

local function relative_note_filename(filename)
  return vim.fs.relpath(vim.fn.getcwd(), filename) or filename
end

local function find_note(filename, lnum)
  for _, note in ipairs(M.notes) do
    if note.filename == filename and note.lnum == lnum then
      return note
    end
  end
end

local function loaded_note_buffer(filename)
  local buf = vim.fn.bufnr(filename)
  if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
    return buf
  end
end

local function create_note(buf, filename, lnum, text)
  local note = {
    filename = filename,
    lnum = lnum,
    text = M.config.symbol .. " " .. text,
    note = text,
  }
  place_note(buf, note)
  table.insert(M.notes, note)
  M.save_notes()
  refresh_active_note_list()
  return note
end

local function update_note(note, text, buf)
  note.note = text
  note.text = M.config.symbol .. " " .. text

  local source_buf = buf or loaded_note_buffer(note.filename)
  if source_buf then
    place_note(source_buf, note)
  end

  M.save_notes()
  refresh_active_note_list()
end

local function delete_note(note, buf)
  local source_buf = buf or loaded_note_buffer(note.filename)
  if source_buf then
    sync_notes_for_buf(source_buf)
  end

  if source_buf and note.note_id then
    vim.api.nvim_buf_del_extmark(source_buf, note_namespace, note.note_id)
  end

  for i, candidate in ipairs(M.notes) do
    if candidate == note then
      table.remove(M.notes, i)
      break
    end
  end

  M.save_notes()
  refresh_active_note_list()
end

------------------------------------------------------------
-- Setup function for user configuration
------------------------------------------------------------
function M.setup(opts)
  local config_opts = vim.deepcopy(opts or {})
  config_opts.base_dir = nil
  M.config = vim.tbl_deep_extend("force", {}, defaults, config_opts)
  M.load_notes()
end

local function ensure_autocmds()
  if autocmds_registered then
    return
  end

  autocmds_registered = true

  -- Create autocmd to delete the file and folder if empty on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      if #M.notes == 0 then
        local dir = vim.fn.fnamemodify(M.config.notes_file, ":h")

        vim.fn.delete(M.config.notes_file)
        vim.fn.delete(dir, "d")
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufReadPost", {
    group = augroup,
    callback = function(ev)
      local bufname = vim.api.nvim_buf_get_name(ev.buf)
      for _, note in ipairs(M.notes) do
        if note.filename == bufname then
          local line_count = vim.api.nvim_buf_line_count(ev.buf)
          if note.lnum > 0 and note.lnum <= line_count then
            place_note(ev.buf, note)
          end
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    callback = function(ev)
      sync_notes_for_buf(ev.buf)
      M.save_notes()
    end,
  })
end

------------------------------------------------------------
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

local function render_base_file_preview(pane, filename, lnum, spec, top_padding, file_lines)
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

------------------------------------------------------------
-- Edit note in floating window
------------------------------------------------------------
local function edit_in_floating_window(initial_text, on_submit, preview)
  local preview_top_padding = vim.wo.scrolloff
  local layout = floating.editor_layout(
    M.config.window_style,
    M.config.preview_split_ratio,
    M.config.file_preview and preview and preview.filename
  )
  local panes = {}
  if layout.preview then
    panes.preview = floating.open(vim.tbl_extend("force", layout.preview, {
      enter = false,
      focusable = false,
    }))
    render_base_file_preview(panes.preview, preview.filename, preview.lnum, layout.preview, preview_top_padding)
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

  -- acwrite buffers still need a name for :w to dispatch BufWriteCmd.
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
      M.SaveNote(float_buf)
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
    on_submit(text)
  end

  note_buffer_savers[float_buf] = function()
    local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
    local text = table.concat(lines, " "):gsub("^%s*(.-)%s*$", "%1")
    finish(text)
  end

  vim.api.nvim_buf_create_user_command(float_buf, "SaveNote", function()
    M.SaveNote(float_buf)
  end, {})
end

function M.SaveNote(bufnr)
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

------------------------------------------------------------
-- List notes in floating window
------------------------------------------------------------
local function goto_note(note)
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

local function build_note_preview(note, max_height)
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

----------------------------------------------------------
-- Edit already existsing note
----------------------------------------------------------
function M.edit_note(note)
  edit_in_floating_window(note.note, function(updated_text)
    if updated_text ~= "" then
      update_note(note, updated_text)
      vim.notify("Note updated", vim.log.levels.INFO)
    else
      delete_note(note)
      vim.notify("Note deleted", vim.log.levels.INFO)
    end
    vim.cmd("redraw")
  end, { filename = note.filename, lnum = note.lnum })
end

------------------------------------------------------------
-- Add a note at current line
------------------------------------------------------------
function M.add_note()
  local selected_note = selected_list_note()
  if selected_note then
    M.edit_note(selected_note)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  sync_notes_for_buf(buf)

  local existing_note = find_note(file, line)
  if existing_note then
    M.edit_note(existing_note)
    return
  end

  edit_in_floating_window(nil, function(note)
    if note ~= "" then
      create_note(buf, file, line, note)
      vim.cmd("redraw")
      vim.notify("Note added", vim.log.levels.INFO)
    end
  end, { filename = file, lnum = line })
end

------------------------------------------------------------
-- Remove note from current line
------------------------------------------------------------
function M.remove_note(selected_note)
  if selected_note and (not selected_note.filename or not selected_note.lnum) then
    selected_note = nil
  end

  if not selected_note then
    selected_note = selected_list_note()
  end

  if selected_note then
    delete_note(selected_note)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  sync_notes_for_buf(buf)

  local note = find_note(file, line)
  if note then
    delete_note(note, buf)
  else
    M.save_notes()
  end
end

------------------------------------------------------------
-- Show note for note at current line
------------------------------------------------------------
function M.show_note()
  local selected_note = selected_list_note()
  if selected_note then
    M.edit_note(selected_note)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  sync_notes_for_buf(buf)

  local note = find_note(file, line)
  if note then
    M.edit_note(note)
    return
  end

  vim.notify("No note at current line", vim.log.levels.WARN)
end

------------------------------------------------------------
-- Show notes in quickfix
------------------------------------------------------------
function M.show_notes()
  if #M.notes == 0 then
    vim.notify("No notes available", vim.log.levels.WARN)
    return
  end

  if active_note_list then
    active_note_list.refresh()
    return
  end

  active_note_list = note_list.open({
    config = M.config,
    notes = function()
      return M.notes
    end,
    relative_filename = relative_note_filename,
    delete_note = M.remove_note,
    goto_note = goto_note,
    note_preview = build_note_preview,
    render_file_preview = render_base_file_preview,
    ui_namespace = ui_namespace,
    on_close = function()
      active_note_list = nil
    end,
  })
end

------------------------------------------------------------
-- Persistence: Save and Load
------------------------------------------------------------
function M.save_notes()
  local dir = vim.fn.fnamemodify(M.config.notes_file, ":h")
  if vim.fn.mkdir(dir, "p") == 0 then
    vim.notify("Notes: failed to create directory " .. dir, vim.log.levels.ERROR)
    return
  end
  sync_all_loaded_notes()

  local json = vim.fn.json_encode(M.notes)
  local f, err = io.open(M.config.notes_file, "w")
  if f then
    f:write(json)
    f:close()
  else
    vim.notify("Notes: failed to save " .. M.config.notes_file .. " — " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.load_notes()
  ensure_autocmds()

  local f = io.open(M.config.notes_file, "r")
  if f then
    local content = f:read("*a")
    f:close()
    if content and #content > 0 then
      local ok, decoded = pcall(vim.fn.json_decode, content)
      if ok and type(decoded) == "table" then
        M.notes = decoded
      else
        vim.notify("Notes: invalid JSON in " .. M.config.notes_file, vim.log.levels.ERROR)
        M.notes = {}
      end
    end
  end
end

return M
