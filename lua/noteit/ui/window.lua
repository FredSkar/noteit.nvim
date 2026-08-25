--- Low-level floating-window primitives.
--
-- This is the only module that touches `nvim_open_win`/`nvim_win_set_config`/
-- `nvim_win_close` directly, and the only place that does frame/grid layout
-- math or cursor-hiding. `noteit.ui.handler` builds on top of this module to
-- turn a `panes` config into a running, interactive window group; nothing in
-- here knows about pane modules, `setup`/`render` callbacks, or actions —
-- it only deals in buffers, windows, rectangles, and raw config tables.
-- @module noteit.ui.window
local M = {}

local function clamp(value, minimum, maximum)
  return math.max(minimum, math.min(value, maximum))
end

--- Return the current UI's width and height in columns and rows.
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

--- Split a shared dimension ("all panes in this column/row must line up")
-- into fractions: panes that request an explicit fraction keep it, and the
-- fraction left over (`1 - sum of explicit fractions`) is split evenly
-- across the remaining panes ("take what's left of the window").
-- @param keys table an array of ids sharing the dimension (e.g. row numbers
-- in one column)
-- @param explicit_for function(key) -> number|nil the pane-requested fraction
-- @return table id -> resolved fraction (0-1)
-- @local
local function leftover_fractions(keys, explicit_for)
  local sum = 0
  local auto_keys = {}
  local fractions = {}

  for _, key in ipairs(keys) do
    local requested = explicit_for(key)
    if requested then
      fractions[key] = requested
      sum = sum + requested
    else
      auto_keys[#auto_keys + 1] = key
    end
  end

  local remainder = math.max(0, 1 - sum)
  local per_auto = #auto_keys > 0 and (remainder / #auto_keys) or 0
  for _, key in ipairs(auto_keys) do
    fractions[key] = per_auto
  end

  return fractions
end

--- Compute each pane's `{width, height, row, col}` rectangle inside `frame`.
--
-- Panes are grouped by `pane.col` (defaults to `1`; the grid has columns `1`
-- and `2`). A column's width is whichever pane in it sets `pane.width`
-- (a fraction of the frame's width); if none do, the column takes whatever
-- width is left over after the other column, split evenly if both are auto.
--
-- Within a column, a single pane that omits `pane.row` spans the column's
-- full height. Two panes sharing a column set `pane.row` to `1` (top) or
-- `2` (bottom); their heights follow the same explicit-or-leftover rule as
-- column widths, using `pane.height` fractions of the frame's height, with
-- `pane.max_height` optionally capping a row at a fixed number of rows (see
-- `noteit.ui.handler.open`'s docs for the full pane config schema).
-- @param the_frame table a frame, as returned by `M.frame`
-- @param panes table an array of pane configs
-- @return table rectangles, one per pane, indexed the same as `panes`
function M.compute_grid(the_frame, panes)
  local columns = {}
  local column_order = {}
  for index, pane in ipairs(panes) do
    local col = pane.col or 1
    if not columns[col] then
      columns[col] = {}
      column_order[#column_order + 1] = col
    end
    table.insert(columns[col], index)
  end
  table.sort(column_order)

  local column_width_fraction = leftover_fractions(column_order, function(col)
    for _, index in ipairs(columns[col]) do
      if panes[index].width then
        return panes[index].width
      end
    end
    return nil
  end)

  -- Fractions are resolved against the space actually available for panes,
  -- i.e. the frame minus the gaps *between* columns/rows, so that pane
  -- edges plus gaps add up to exactly the frame's size instead of
  -- overflowing it by one gap per extra column/row.
  local available_width = clamp(the_frame.width - the_frame.gap_x * (#column_order - 1), 1, the_frame.width)

  local rects = {}
  local x = the_frame.col
  for _, col in ipairs(column_order) do
    local indices = columns[col]
    local column_width = clamp(math.floor(available_width * column_width_fraction[col]), 1, available_width)

    if #indices == 1 and not panes[indices[1]].row then
      -- The only pane in this column and no row given: span the full height.
      rects[indices[1]] = {
        width = column_width,
        height = the_frame.height,
        row = the_frame.row,
        col = x,
      }
    else
      local by_row = {}
      local row_order = {}
      for _, index in ipairs(indices) do
        local row = panes[index].row or 1
        by_row[row] = index
        row_order[#row_order + 1] = row
      end
      table.sort(row_order)

      local row_height_fraction = leftover_fractions(row_order, function(row)
        return panes[by_row[row]].height
      end)

      local available_height = clamp(the_frame.height - the_frame.gap_y * (#row_order - 1), 1, the_frame.height)

      -- Resolve pixel heights, then cap any row with `max_height` and hand
      -- the reclaimed space back to rows with neither an explicit `height`
      -- nor a `max_height` (there is normally at most one such row per
      -- column, e.g. a note list sized around a capped note-preview pane).
      local row_pixel_height = {}
      local reclaimed = 0
      local flexible_rows = {}
      for _, row in ipairs(row_order) do
        local pane = panes[by_row[row]]
        local pane_height = clamp(math.floor(available_height * row_height_fraction[row]), 1, available_height)
        if pane.max_height then
          local capped = math.min(pane_height, pane.max_height)
          reclaimed = reclaimed + (pane_height - capped)
          pane_height = capped
        elseif not pane.height then
          flexible_rows[#flexible_rows + 1] = row
        end
        row_pixel_height[row] = pane_height
      end

      if reclaimed > 0 and #flexible_rows > 0 then
        local bonus = math.floor(reclaimed / #flexible_rows)
        for _, row in ipairs(flexible_rows) do
          row_pixel_height[row] = row_pixel_height[row] + bonus
        end
      end

      local y = the_frame.row
      for _, row in ipairs(row_order) do
        local index = by_row[row]
        local pane_height = row_pixel_height[row]
        rects[index] = {
          width = column_width,
          height = pane_height,
          row = y,
          col = x,
        }
        y = y + pane_height + the_frame.gap_y
      end
    end

    x = x + column_width + the_frame.gap_x
  end

  return rects
end

--- Convert a resolved rectangle + pane config into an `nvim_open_win` config.
-- @param rect table `{ width, height, row, col }`, as returned by `M.compute_grid`
-- @param pane table the pane config (see `noteit.ui.handler.open`)
-- @param module_style table|nil the pane module's `style` defaults
-- @return table a config suitable for `nvim_open_win`/`nvim_win_set_config`
function M.win_config(rect, pane, module_style)
  local border = pane.border
  if border == nil then
    border = module_style and module_style.border
  end
  if border == nil then
    border = "rounded"
  end

  local focusable = pane.focusable
  if focusable == nil then
    focusable = module_style and module_style.focusable
  end

  local config = {
    relative = "editor",
    width = rect.width,
    height = rect.height,
    row = rect.row,
    col = rect.col,
    style = "minimal",
    border = border,
    focusable = focusable,
  }

  local title = pane.title
  if title == nil then
    title = module_style and module_style.title
  end
  if title then
    config.title = " " .. title .. " "
    config.title_pos = "center"
  end

  return config
end

--- Create a floating window for `buf` from a resolved rectangle + pane config.
-- @param buf number the buffer to display
-- @param enter boolean whether to focus the new window immediately
-- @param rect table `{ width, height, row, col }`, as returned by `M.compute_grid`
-- @param pane table the pane config
-- @param module_style table|nil the pane module's `style` defaults
-- @return number the created window handle
function M.open(buf, enter, rect, pane, module_style)
  return vim.api.nvim_open_win(buf, enter, M.win_config(rect, pane, module_style))
end

--- Update an existing floating window's size/position/style in place.
-- @param win number the window to update
-- @param rect table the new rectangle
-- @param pane table the pane config
-- @param module_style table|nil the pane module's `style` defaults
function M.update(win, rect, pane, module_style)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_config(win, M.win_config(rect, pane, module_style))
  end
end

--- Close a window if it's still valid. Safe to call repeatedly.
-- @param win number|nil the window to close
function M.close(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
  end
end

--- Replace a buffer's contents and apply readonly/filetype/highlights, and
-- (if `win` is a valid window showing it) wrap/linebreak/breakindent.
-- @param buf number the buffer to render into
-- @param win number|nil the window displaying `buf`, if any
-- @param lines table the lines to display
-- @param opts table|nil `readonly`, `filetype`, `wrap`, `linebreak`,
-- `breakindent`, `namespace`, and `highlights`
-- (`{ group, line, col_start, col_end }` entries)
function M.set_lines(buf, win, lines, opts)
  opts = opts or {}
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = not opts.readonly
  vim.bo[buf].readonly = opts.readonly or false
  vim.bo[buf].filetype = opts.filetype or vim.bo[buf].filetype

  if win and vim.api.nvim_win_is_valid(win) then
    vim.wo[win].wrap = opts.wrap or false
    vim.wo[win].linebreak = opts.linebreak or false
    vim.wo[win].breakindent = opts.breakindent or false
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

local hidden_cursor_hl = "NoteitHiddenCursor"

--- (Re)define a highlight group whose fg/bg match `Normal`, making the
-- terminal-drawn cursor cell blend into the background wherever a terminal
-- honors OSC 12 cursor-color requests. Recomputed on every call (cheap) so
-- it tracks colorscheme changes.
-- @local
local function ensure_hidden_cursor_highlight()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  vim.api.nvim_set_hl(0, hidden_cursor_hl, {
    fg = normal.bg,
    bg = normal.bg,
    blend = 100,
  })
end

local saved_guicursor
local hidden_cursor_depth = 0

--- Shrink the cursor to a near-invisible 1%-height hairline for every mode.
-- Cursor color is not portable across terminals, but cursor *shape* is, so
-- this is the most reliable way to minimize the cursor everywhere, including
-- VTE-based terminals (e.g. GNOME Terminal) that ignore OSC 12 cursor-color
-- requests. Calls nest; the original `guicursor` is restored once every
-- caller has popped.
function M.push_hidden_cursor()
  ensure_hidden_cursor_highlight()

  if hidden_cursor_depth == 0 then
    saved_guicursor = vim.o.guicursor
    local modes = { "n", "v", "i", "c", "ci", "cr", "o", "r", "sm", "t" }
    local parts = {}
    for _, mode in ipairs(modes) do
      parts[#parts + 1] = mode .. ":hor1-" .. hidden_cursor_hl .. "-blinkon0"
    end
    vim.o.guicursor = table.concat(parts, ",")
  end

  hidden_cursor_depth = hidden_cursor_depth + 1
end

--- Undo one `M.push_hidden_cursor` call, restoring the original `guicursor`
-- once the outermost call has been popped.
function M.pop_hidden_cursor()
  hidden_cursor_depth = math.max(0, hidden_cursor_depth - 1)
  if hidden_cursor_depth == 0 and saved_guicursor then
    vim.o.guicursor = saved_guicursor
    saved_guicursor = nil
  end
end

return M
