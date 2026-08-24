--- Public API for adding, editing, removing, and listing project notes.
-- @module noteit
local note_editor = require("noteit.ui.note_editor")
local note_list = require("noteit.ui.note_list")
local note_state = require("noteit.state")

local M = {}

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

local active_note_list

--- Refresh the open note list after the note data changes.
-- @local
local function refresh_active_note_list()
  if active_note_list then
    active_note_list.refresh()
  end
end

--- Return the note selected in the list when that list has focus.
-- @return table|nil the selected note, or `nil` if no list is focused
-- @local
local function selected_list_note()
  if active_note_list and active_note_list.is_focused() then
    return active_note_list.selected_note()
  end
end

local state = note_state.new({
  augroup = augroup,
  namespace = note_namespace,
  get_config = function()
    return M.config
  end,
  on_change = refresh_active_note_list,
})

M.notes = state.notes

--- Open the note editor and connect its submit callback to the caller.
-- @param initial_text string|nil the text to prefill the editor with
-- @param preview table|nil `{ filename, lnum }` for the source preview
-- @param on_submit function called with the submitted text
-- @local
local function open_note_editor(initial_text, preview, on_submit)
  note_editor.open(initial_text, {
    config = M.config,
    preview = preview,
    ui_namespace = ui_namespace,
    on_submit = on_submit,
  })
end

--- Merge user options with the plugin defaults and load persisted notes.
-- @param opts table|nil user configuration overrides
function M.setup(opts)
  local config_opts = vim.deepcopy(opts or {})
  config_opts.base_dir = nil
  M.config = vim.tbl_deep_extend("force", {}, defaults, config_opts)
  M.load_notes()
end

--- Open an existing note for editing, deleting it when submitted empty.
-- @param note table the note to edit
function M.edit_note(note)
  open_note_editor(note.note, { filename = note.filename, lnum = note.lnum }, function(updated_text)
    if updated_text ~= "" then
      state.update_note(note, updated_text)
      vim.notify("Note updated", vim.log.levels.INFO)
    else
      state.delete_note(note)
      vim.notify("Note deleted", vim.log.levels.INFO)
    end
    vim.cmd("redraw")
  end)
end

--- Add a note at the current line, or edit an existing/selected note.
function M.add_note()
  local selected_note = selected_list_note()
  if selected_note then
    M.edit_note(selected_note)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  state.sync_notes_for_buf(buf)

  local existing_note = state.find_note(file, line)
  if existing_note then
    M.edit_note(existing_note)
    return
  end

  open_note_editor(nil, { filename = file, lnum = line }, function(note)
    if note ~= "" then
      state.create_note(buf, file, line, note)
      vim.cmd("redraw")
      vim.notify("Note added", vim.log.levels.INFO)
    end
  end)
end

--- Remove the selected note or the note at the current line.
-- @param selected_note table|nil an explicit note to remove, bypassing lookup
function M.remove_note(selected_note)
  if selected_note and (not selected_note.filename or not selected_note.lnum) then
    selected_note = nil
  end

  if not selected_note then
    selected_note = selected_list_note()
  end

  if selected_note then
    state.delete_note(selected_note)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  state.sync_notes_for_buf(buf)

  local note = state.find_note(file, line)
  if note then
    state.delete_note(note, buf)
  else
    M.save_notes()
  end
end

--- Edit the selected note or the note at the current line.
function M.show_note()
  local selected_note = selected_list_note()
  if selected_note then
    M.edit_note(selected_note)
    return
  end

  local buf = vim.api.nvim_get_current_buf()
  local file = vim.api.nvim_buf_get_name(buf)
  local line = vim.api.nvim_win_get_cursor(0)[1]

  state.sync_notes_for_buf(buf)

  local note = state.find_note(file, line)
  if note then
    M.edit_note(note)
    return
  end

  vim.notify("No note at current line", vim.log.levels.WARN)
end

--- Open the interactive note list, or refresh it when already open.
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
    relative_filename = state.relative_note_filename,
    delete_note = M.remove_note,
    goto_note = note_editor.goto_note,
    note_preview = note_editor.build_note_preview,
    render_file_preview = function(pane, filename, lnum, spec, top_padding, file_lines)
      note_editor.render_file_preview(pane, filename, lnum, spec, top_padding, file_lines, ui_namespace)
    end,
    ui_namespace = ui_namespace,
    on_close = function()
      active_note_list = nil
    end,
  })
end

--- Persist all notes through the state module.
function M.save_notes()
  state.save_notes()
end

--- Load persisted notes through the state module.
function M.load_notes()
  state.load_notes()
end

return M
