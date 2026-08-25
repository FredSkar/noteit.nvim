--- Central window/pane handler.
--
-- This is the only module that touches `nvim_open_win`/`nvim_win_set_config`/
-- `nvim_win_close` directly. A "window" opened through `M.open` is a centered
-- floating frame holding up to a 2x2 grid of panes (see `M.open`'s `panes`
-- option below). Each pane is a small module under `noteit.ui.panes.*` that
-- only implements `setup`/`render` callbacks (see `noteit.ui.panes.README`-
-- style docs in `ARCHITECTURE.md`) — panes never touch another pane's buffer
-- or window directly; they coordinate only through the `ctx` table this
-- handler passes to their callbacks.
-- @module noteit.ui.handler
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
-- @local
local function frame(style)
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
-- column widths, using `pane.height` fractions of the frame's height.
-- @param panes table an array of pane configs (see `M.open`)
-- @return table rectangles, one per pane, indexed the same as `panes`
-- @local
local function compute_grid(the_frame, panes)
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

  local rects = {}
  local x = the_frame.col
  for _, col in ipairs(column_order) do
    local indices = columns[col]
    local column_width = clamp(math.floor(the_frame.width * column_width_fraction[col]), 1, the_frame.width)

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

      -- Resolve pixel heights, then cap any row with `max_height` and hand
      -- the reclaimed space back to rows with neither an explicit `height`
      -- nor a `max_height` (there is normally at most one such row per
      -- column, e.g. a note list sized around a capped note-preview pane).
      local row_pixel_height = {}
      local reclaimed = 0
      local flexible_rows = {}
      for _, row in ipairs(row_order) do
        local pane = panes[by_row[row]]
        local pane_height = clamp(math.floor(the_frame.height * row_height_fraction[row]), 1, the_frame.height)
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
-- @local
local function win_config(rect, pane, module_style)
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
-- @local
local function push_hidden_cursor()
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

--- Undo one `push_hidden_cursor` call, restoring the original `guicursor`
-- once the outermost call has been popped.
-- @local
local function pop_hidden_cursor()
  hidden_cursor_depth = math.max(0, hidden_cursor_depth - 1)
  if hidden_cursor_depth == 0 and saved_guicursor then
    vim.o.guicursor = saved_guicursor
    saved_guicursor = nil
  end
end

--- Replace a pane's buffer contents and apply readonly/filetype/highlights.
-- Exposed to pane modules as `ctx.set_lines`.
-- @param slot table the pane's internal `{ buf, win }` slot
-- @param lines table the lines to display
-- @param opts table|nil `readonly`, `filetype`, `wrap`, `linebreak`,
-- `breakindent`, `namespace`, and `highlights`
-- (`{ group, line, col_start, col_end }` entries)
-- @local
local function set_pane_lines(slot, lines, opts)
  opts = opts or {}
  local buf = slot.buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].readonly = false
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = not opts.readonly
  vim.bo[buf].readonly = opts.readonly or false
  vim.bo[buf].filetype = opts.filetype or vim.bo[buf].filetype

  if slot.win and vim.api.nvim_win_is_valid(slot.win) then
    vim.wo[slot.win].wrap = opts.wrap or false
    vim.wo[slot.win].linebreak = opts.linebreak or false
    vim.wo[slot.win].breakindent = opts.breakindent or false
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

local session_id = 0

--- Open a floating window holding up to a 2x2 grid of panes.
-- @param opts table
--   `window_style`: frame sizing/spacing, see `frame()`.
--   `panes`: array of pane configs, each `{ type, col, row, width, height,
--     max_height, enter, focusable, border, title }`:
--       - `type` (required): pane module name under `noteit.ui.panes.*`.
--       - `col` (`1`|`2`, default `1`): grid column.
--       - `row` (`1`|`2`, optional): grid row within the column; omit to
--         span the column's full height (only valid when this pane is the
--         only one in its column).
--       - `width`/`height` (`0`-`1`, optional): fraction of the frame's
--         width/height for this pane's column/row. If omitted, the
--         column/row takes whatever fraction is left over (split evenly
--         if more than one sibling also omits it).
--       - `max_height` (rows, optional): caps a row's computed height at a
--         fixed number of rows; the difference is handed back to sibling
--         rows in the same column that set neither `height` nor
--         `max_height`. Useful for a pane that should stay a fixed size
--         (e.g. a short text preview) while a sibling grows to fill the
--         rest of the column.
--       - `enter` (boolean, default `false`): focus this pane on open.
--         Exactly one pane per window should normally set this.
--       - `focusable` (boolean, optional): overrides the pane module's
--         `style.focusable` default (`true` if neither is set).
--       - `border`/`title` (optional): override the pane module's
--         `style.border`/`style.title`.
--   `data`: arbitrary read-only table passed through as `ctx.opts` to every
--     pane's `setup`/`render` (config, getters, etc. supplied by the caller).
--   `initial_state`: optional table used as the starting `ctx.state`
--     blackboard, seeded before the first render (e.g. so a pane whose
--     content never changes, like the note editor, can hand a fixed
--     `{filename, lnum}` target to a sibling `file_preview` pane).
--   `actions`: table of named functions a pane can invoke via
--     `ctx.dispatch(name, ...)` — the only way a pane may act outside its
--     own window (e.g. opening a note's source file, deleting a note).
--   `hide_cursor` (boolean, default `false`): minimize the cursor while any
--     pane in this window is focused (see `push_hidden_cursor`).
--   `on_close` (function, optional): called once when the window closes.
-- @return table the session: `{ state, close, render, is_focused }`.
--   `state` is the shared blackboard table passed to every pane as
--   `ctx.state`.
function M.open(opts)
  opts = opts or {}
  session_id = session_id + 1

  local panes = opts.panes or {}
  local modules = {}
  for _, pane in ipairs(panes) do
    modules[#modules + 1] = require("noteit.ui.panes." .. pane.type)
  end

  local slots = {}
  for i in ipairs(panes) do
    slots[i] = { buf = nil, win = nil }
  end

  local session = {
    state = opts.initial_state or {},
    closed = false,
  }
  local group = vim.api.nvim_create_augroup("noteit_handler_" .. session_id, { clear = true })
  local rects = compute_grid(frame(opts.window_style or {}), panes)

  --- Build the `ctx` table passed to a pane's `setup`/`render` for this call.
  -- @local
  local function build_ctx(index)
    local slot = slots[index]
    return {
      buf = slot.buf,
      win = slot.win,
      opts = opts.data or {},
      state = session.state,
      dispatch = function(name, ...)
        local action = (opts.actions or {})[name]
        if not action then
          error(string.format("noteit ui handler: no action registered for %q", name), 2)
        end
        return action(...)
      end,
      render = function(pane_type)
        session.render(pane_type)
      end,
      map = function(modes, lhs, fn)
        vim.keymap.set(modes, lhs, fn, { buffer = slot.buf, silent = true })
      end,
      close = function()
        session.close()
      end,
      set_lines = function(lines, render_opts)
        set_pane_lines(slot, lines, render_opts)
      end,
    }
  end

  --- Close one pane's window (its scratch buffer wipes itself via
  -- `bufhidden = wipe`, set by `set_pane_lines`). Safe to call repeatedly.
  -- @local
  local function close_pane(index)
    local slot = slots[index]
    if slot.win and vim.api.nvim_win_is_valid(slot.win) then
      vim.api.nvim_win_close(slot.win, true)
    end
    slot.buf, slot.win = nil, nil
  end

  --- Create the pane's floating window/buffer and run its `setup` once.
  -- @local
  local function open_pane(index)
    local pane = panes[index]
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, win_config(rects[index], pane, modules[index].style))
    slots[index].buf, slots[index].win = buf, win

    if pane.enter then
      vim.api.nvim_set_current_win(win)

      -- The focused pane drives the whole window group's lifetime: if its
      -- buffer goes away (`:bd`, `:close`, switching away from the float),
      -- tear down every other pane too.
      vim.api.nvim_create_autocmd({ "BufWipeout", "BufWinLeave" }, {
        group = group,
        buffer = buf,
        once = true,
        callback = function()
          session.close()
        end,
      })
    end

    if modules[index].setup then
      modules[index].setup(build_ctx(index))
    end
  end

  --- (Re)render one pane by index: opens/re-creates its window if needed,
  -- then calls the pane's `render` (optional; panes with static content,
  -- like the note editor, may omit it). If `render` returns `false`, the
  -- pane's window is torn down until a future render call has content again.
  -- @local
  local function render_pane(index)
    if not slots[index].win or not vim.api.nvim_win_is_valid(slots[index].win) then
      open_pane(index)
    end

    local keep_visible = true
    if modules[index].render then
      keep_visible = modules[index].render(build_ctx(index))
    end
    if keep_visible == false then
      close_pane(index)
    end
  end

  --- Render one pane type, or every pane when `pane_type` is `nil`. Stops
  -- early if a pane's render closed the whole session (e.g. the note list
  -- becoming empty), so later panes in the loop aren't reopened afterward.
  function session.render(pane_type)
    for index, pane in ipairs(panes) do
      if session.closed then
        return
      end
      if pane_type == nil or pane.type == pane_type then
        render_pane(index)
      end
    end
  end

  --- Whether any pane in this window currently has focus.
  -- @return boolean
  function session.is_focused()
    local current = vim.api.nvim_get_current_buf()
    for _, slot in ipairs(slots) do
      if slot.buf == current then
        return true
      end
    end
    return false
  end

  --- Close every pane and tear down the window group. Safe to call more
  -- than once.
  function session.close()
    if session.closed then
      return
    end
    session.closed = true

    if opts.hide_cursor then
      pop_hidden_cursor()
    end

    for index in ipairs(panes) do
      close_pane(index)
    end

    pcall(vim.api.nvim_del_augroup_by_id, group)

    if opts.on_close then
      opts.on_close()
    end
  end

  if opts.hide_cursor then
    push_hidden_cursor()
  end

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      rects = compute_grid(frame(opts.window_style or {}), panes)
      for index, pane in ipairs(panes) do
        if slots[index].win and vim.api.nvim_win_is_valid(slots[index].win) then
          vim.api.nvim_win_set_config(slots[index].win, win_config(rects[index], pane, modules[index].style))
        end
      end
      session.render()
    end,
  })

  session.render()

  return session
end

return M
