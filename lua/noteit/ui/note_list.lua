--- Interactive floating note list with navigation and previews.
-- @module noteit.ui.note_list
local floating = require("noteit.ui.floating")

local M = {}

--- Open an interactive note list using the supplied state and UI callbacks.
-- @param deps table `config`, `notes`, `relative_filename`, `delete_note`,
-- `goto_note`, `note_preview`, `render_file_preview`, `ui_namespace`, `on_close`
-- @return table the session, exposing `selected_note`, `is_focused`, `refresh`
function M.open(deps)
  local config = deps.config
  local preview_top_padding = vim.wo.scrolloff
  local layout = floating.list_layout(
    config.window_style,
    config.preview_split_ratio,
    config.note_preview_lines,
    config.file_preview,
    config.list_note_preview
  )
  local panes = {
    list = floating.open(layout.list),
  }
  local displayed_notes = {}
  local selected_row = 1
  local cached_filename
  local cached_file_lines
  local controller
  local session = {}

  --- Read and cache source lines for the currently selected note.
  -- @param filename string the file to read
  -- @return table|false the file's lines, or `false` if it could not be read
  -- @local
  local function file_lines(filename)
    if filename ~= cached_filename then
      cached_filename = filename
      local ok, lines = pcall(vim.fn.readfile, filename)
      cached_file_lines = ok and lines or false
    end

    return cached_file_lines
  end

  --- Render note locations and the current selection highlight.
  -- @param selected_index number|nil the row to highlight as selected
  -- @local
  local function render_note_list(selected_index)
    local list_lines = {}
    local highlights = {}

    for i, note in ipairs(deps.notes()) do
      list_lines[i] = string.format("%d. %s:%d", i, deps.relative_filename(note.filename), note.lnum)
      highlights[#highlights + 1] = {
        group = "Bold",
        line = i - 1,
        col_start = 0,
        col_end = #tostring(i) + 1,
      }
    end

    if selected_index and selected_index >= 1 and selected_index <= #list_lines then
      highlights[#highlights + 1] = {
        group = "Visual",
        line = selected_index - 1,
      }
    end

    floating.render(panes.list, list_lines, {
      readonly = true,
      namespace = deps.ui_namespace,
      highlights = highlights,
    })
  end

  --- Refresh the selected note's note and source previews.
  -- @local
  local function sync_selected_previews()
    if not vim.api.nvim_win_is_valid(panes.list.win) then
      controller:close()
      return
    end

    local note = displayed_notes[selected_row]
    render_note_list(selected_row)

    if not note then
      floating.close({ panes.note_preview, panes.code_preview })
      panes.note_preview, panes.code_preview = nil, nil
      return
    end

    if layout.note_preview then
      panes.note_preview = panes.note_preview
        or floating.open(vim.tbl_extend("force", layout.note_preview, {
          enter = false,
          focusable = false,
        }))
      floating.update(
        panes.note_preview,
        vim.tbl_extend("force", layout.note_preview, {
          focusable = false,
        })
      )
      floating.render(panes.note_preview, deps.note_preview(note, layout.note_preview.height), {
        readonly = true,
        filetype = "text",
        wrap = true,
        linebreak = true,
        breakindent = true,
      })
    else
      floating.close({ panes.note_preview })
      panes.note_preview = nil
    end

    if layout.code_preview and note.filename and note.filename ~= "" then
      panes.code_preview = panes.code_preview
        or floating.open(vim.tbl_extend("force", layout.code_preview, {
          enter = false,
          focusable = false,
        }))
      deps.render_file_preview(
        panes.code_preview,
        note.filename,
        note.lnum,
        vim.tbl_extend("force", layout.code_preview, {
          focusable = false,
        }),
        preview_top_padding,
        file_lines(note.filename)
      )
    else
      floating.close({ panes.code_preview })
      panes.code_preview = nil
    end
  end

  --- Rebuild the displayed-note snapshot and refresh all panes.
  -- @local
  local function refresh()
    displayed_notes = {}
    for i, note in ipairs(deps.notes()) do
      displayed_notes[i] = note
    end

    if #displayed_notes == 0 then
      vim.notify("No notes available", vim.log.levels.WARN)
      controller:close()
      return
    end

    selected_row = math.max(1, math.min(selected_row, #displayed_notes))
    sync_selected_previews()
  end

  --- Move the selection while keeping it within the displayed notes.
  -- @param delta number the number of rows to move by (negative moves up)
  -- @local
  local function move_selection(delta)
    if #displayed_notes == 0 then
      return
    end

    selected_row = math.max(1, math.min(selected_row + delta, #displayed_notes))
    sync_selected_previews()
  end

  controller = floating.controller({
    panes = panes,
    on_close = deps.on_close,
    on_resize = function()
      layout = floating.list_layout(
        config.window_style,
        config.preview_split_ratio,
        config.note_preview_lines,
        config.file_preview,
        config.list_note_preview
      )
      floating.update(panes.list, layout.list)
      if #displayed_notes > 0 then
        sync_selected_previews()
      end
    end,
  })

  refresh()

  --- Return the currently selected note.
  -- @return table|nil the selected note, if any
  function session.selected_note()
    return displayed_notes[selected_row]
  end

  --- Check whether the hidden controller buffer currently has focus.
  -- @return boolean whether the list's controller buffer is focused
  function session.is_focused()
    return vim.api.nvim_get_current_buf() == controller.pane.buf
  end

  --- Refresh the list after notes are added, edited, or deleted.
  function session.refresh()
    refresh()
  end

  for _, key in ipairs({ "j", "<Down>", "<Tab>" }) do
    controller:map("n", key, function()
      move_selection(1)
    end)
  end

  for _, key in ipairs({ "k", "<Up>", "<S-Tab>" }) do
    controller:map("n", key, function()
      move_selection(-1)
    end)
  end

  controller:map("n", "<CR>", function()
    local note = session.selected_note()
    if not note then
      return
    end

    controller:close()
    deps.goto_note(note)
  end)

  controller:map("n", "dd", function()
    local note = session.selected_note()
    if not note then
      return
    end

    deps.delete_note(note)
    if controller.closed then
      return
    end
    refresh()
  end)

  controller:map({ "n", "i" }, "<Esc>", function()
    controller:close()
  end)

  return session
end

return M
