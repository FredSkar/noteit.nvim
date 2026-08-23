--- Low-level floating-window primitives: layout, rendering, and lifecycle.
-- @module noteit.ui.floating
local M = {}
local titles = {
  editor = "Note",
  source_preview = "File Preview",
  note_preview = "Note Preview",
  notes_list = "Note List",
}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(value, maximum))
end

--- Return the current UI's width and height in columns and rows.
-- @return number the UI width
-- @return number the UI height
-- @local
local function ui_size()
  local ui = vim.api.nvim_list_uis()[1]
  if ui then
    return ui.width, ui.height
  end

  return vim.o.columns, vim.o.lines
end

--- Calculate the centered floating frame and its configured gaps.
-- @param style table `window_style` configuration: `width`, `height`, `spacing`
-- @return table `{ width, height, row, col, gap_x, gap_y }`
function M.frame(style)
  local ui_width, ui_height = ui_size()
  local width = clamp(math.floor(ui_width * (style.width or 0.8)), 1, ui_width)
  local height = clamp(math.floor(ui_height * (style.height or 0.8)), 1, ui_height)
  local spacing = style.spacing or {}

  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((ui_height - height) / 2)),
    col = math.max(0, math.floor((ui_width - width) / 2)),
    gap_x = math.max(0, math.floor(style.spacing_x or spacing.horizontal or spacing.x or 1)),
    gap_y = math.max(0, math.floor(style.spacing_y or spacing.vertical or spacing.y or 1)),
  }
end

--- Split a dimension into a primary and secondary size, separated by a gap.
-- @param total number the total size to split
-- @param gap number the gap to reserve between the two parts
-- @param ratio number the fraction of `total` given to the secondary part
-- @return number the primary size
-- @return number the secondary size
-- @local
local function split(total, gap, ratio)
  if total <= gap + 1 then
    return total, 0
  end

  local secondary = clamp(math.floor(total * ratio), 1, total - gap - 1)
  return total - secondary - gap, secondary
end

--- Clamp a split ratio to a usable range.
-- @param ratio number|nil the requested ratio
-- @return number the clamped ratio
-- @local
local function split_ratio(ratio)
  return clamp(ratio or 0.35, 0.1, 0.9)
end

--- Calculate editor and source-preview pane sizes for the note editor.
-- @param style table `window_style` configuration
-- @param ratio number the fraction of width given to the source preview
-- @param with_preview boolean whether to reserve space for a source preview
-- @return table `{ editor, preview }` pane layout specs; `preview` is `nil` when absent
function M.editor_layout(style, ratio, with_preview)
  local frame = M.frame(style)
  local editor_width, preview_width = frame.width, 0

  if with_preview then
    editor_width, preview_width = split(frame.width, frame.gap_x, split_ratio(ratio))
  end

  return {
    editor = {
      title = titles.editor,
      width = editor_width,
      height = frame.height,
      row = frame.row,
      col = frame.col,
    },
    preview = preview_width > 0 and {
      title = titles.source_preview,
      width = preview_width,
      height = frame.height,
      row = frame.row,
      col = frame.col + editor_width + frame.gap_x,
    } or nil,
  }
end

--- Calculate list, note-preview, and source-preview pane sizes.
-- @param style table `window_style` configuration
-- @param ratio number the fraction of width given to the source preview
-- @param note_preview_height number the preferred note-preview height
-- @param with_source_preview boolean whether to reserve space for a source preview
-- @param with_note_preview boolean whether to reserve space for a note preview
-- @return table `{ list, note_preview, code_preview }` pane layout specs;
-- `note_preview`/`code_preview` are `nil` when absent
function M.list_layout(style, ratio, note_preview_height, with_source_preview, with_note_preview)
  local frame = M.frame(style)
  local left_width, code_width = frame.width, 0
  if with_source_preview then
    left_width, code_width = split(frame.width, frame.gap_x, split_ratio(ratio))
  end

  local list_height, note_height = frame.height, 0
  if with_note_preview then
    list_height, note_height = split(frame.height, frame.gap_y, 1 - (note_preview_height or 5) / frame.height)
  end

  if note_height > 0 then
    note_height = math.min(note_preview_height or 5, note_height)
    list_height = frame.height - note_height - frame.gap_y
  end

  return {
    list = {
      title = titles.notes_list,
      width = left_width,
      height = list_height,
      row = frame.row,
      col = frame.col,
    },
    note_preview = note_height > 0 and {
      title = titles.note_preview,
      width = left_width,
      height = note_height,
      row = frame.row + list_height + frame.gap_y,
      col = frame.col,
    } or nil,
    code_preview = code_width > 0 and {
      title = titles.source_preview,
      width = code_width,
      height = frame.height,
      row = frame.row,
      col = frame.col + left_width + frame.gap_x,
    } or nil,
  }
end

--- Convert a pane specification into an nvim_open_win configuration.
-- @param spec table pane layout: `width`, `height`, `row`, `col`, `title`, `border`, `focusable`
-- @return table a table suitable for `vim.api.nvim_open_win`/`nvim_win_set_config`
function M.config(spec)
  local config = {
    relative = "editor",
    width = spec.width,
    height = spec.height,
    row = spec.row,
    col = spec.col,
    style = "minimal",
    focusable = spec.focusable,
  }
  config.border = spec.border == nil and "rounded" or spec.border

  if spec.title then
    config.title = " " .. spec.title .. " "
    config.title_pos = "center"
  end

  return config
end

--- Create a floating buffer and window from a pane specification.
-- @param spec table pane layout spec; see `M.config`. `spec.enter` controls focus
-- @return table `{ buf, win }` the created buffer and window handles
function M.open(spec)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, spec.enter ~= false, M.config(spec))
  return { buf = buf, win = win }
end

--- Update an existing floating window's size and position.
-- @param pane table `{ buf, win }` the pane to update
-- @param spec table the new pane layout spec; see `M.config`
function M.update(pane, spec)
  if pane and vim.api.nvim_win_is_valid(pane.win) then
    vim.api.nvim_win_set_config(pane.win, M.config(spec))
  end
end

--- Replace a pane's contents and apply readonly, filetype, and highlights.
-- @param pane table `{ buf, win }` the pane to render into
-- @param lines table the lines to display
-- @param opts table|nil `readonly`, `filetype`, `wrap`, `linebreak`, `breakindent`,
-- `namespace`, and `highlights` (`{ group, line, col_start, col_end }` entries)
function M.render(pane, lines, opts)
  opts = opts or {}
  local buf = pane.buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = not opts.readonly
  vim.bo[buf].readonly = opts.readonly or false
  vim.bo[buf].filetype = opts.filetype or vim.bo[buf].filetype

  if pane.win and vim.api.nvim_win_is_valid(pane.win) then
    vim.wo[pane.win].wrap = opts.wrap or false
    vim.wo[pane.win].linebreak = opts.linebreak or false
    vim.wo[pane.win].breakindent = opts.breakindent or false
  end

  if opts.namespace then
    vim.api.nvim_buf_clear_namespace(buf, opts.namespace, 0, -1)
    for _, highlight in ipairs(opts.highlights or {}) do
      vim.api.nvim_buf_add_highlight(
        buf,
        opts.namespace,
        highlight.group,
        highlight.line,
        highlight.col_start or 0,
        highlight.col_end or -1
      )
    end
  end
end

--- Close every valid window in a pane collection.
-- @param panes table a collection of `{ buf, win }` panes
function M.close(panes)
  for _, pane in pairs(panes) do
    if pane and pane.win and vim.api.nvim_win_is_valid(pane.win) then
      vim.api.nvim_win_close(pane.win, true)
    end
  end
end

local controller_id = 0

--- Return a one-by-one offscreen pane used to capture list input.
-- @return table a pane spec placed just outside the visible UI
-- @local
local function offscreen_config()
  local width, height = ui_size()
  return {
    width = 1,
    height = 1,
    row = height,
    col = width,
    enter = true,
    focusable = true,
    border = "none",
  }
end

--- Create a controller for mappings, cleanup, and resize handling.
-- @param opts table|nil `panes`, `on_close`, `on_resize`
-- @return table the controller, with `reposition`, `close`, and `map` methods
function M.controller(opts)
  opts = opts or {}
  controller_id = controller_id + 1

  local controller = {
    pane = M.open(offscreen_config()),
    panes = opts.panes or {},
    closed = false,
  }
  vim.bo[controller.pane.buf].bufhidden = "wipe"
  vim.bo[controller.pane.buf].modifiable = false
  controller.group = vim.api.nvim_create_augroup("noteit_floating_controller_" .. controller_id, { clear = true })

  --- Keep the controller pane offscreen while the visible panes resize.
  function controller:reposition()
    if self.closed then
      return
    end

    M.update(self.pane, offscreen_config())
  end

  --- Close the controller and all visible panes once.
  function controller:close()
    if self.closed then
      return
    end

    self.closed = true
    if opts.on_close then
      opts.on_close()
    end
    M.close(self.panes)
    M.close({ self.pane })
    pcall(vim.api.nvim_del_augroup_by_id, self.group)
  end

  --- Add a buffer-local mapping to the controller pane.
  function controller:map(modes, lhs, rhs)
    vim.keymap.set(modes, lhs, rhs, { buffer = self.pane.buf, silent = true })
  end

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = controller.group,
    buffer = controller.pane.buf,
    once = true,
    callback = function()
      controller:close()
    end,
  })

  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = controller.group,
    buffer = controller.pane.buf,
    once = true,
    callback = function()
      controller:close()
    end,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = controller.group,
    callback = function()
      controller:reposition()
      if opts.on_resize then
        opts.on_resize()
      end
    end,
  })

  return controller
end

return M
