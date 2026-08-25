--- Pane orchestration: turns a `panes` config into a running window group.
--
-- This module owns the *interaction* between a window (see
-- `noteit.ui.window`, which does all the actual `nvim_open_win`/layout/
-- cursor-hiding work) and its panes: creating each pane's buffer/window via
-- `noteit.ui.window`, running pane `setup`/`render` callbacks, routing
-- `ctx.dispatch` calls to the caller's `actions`, and closing everything
-- down together. Each pane is a small module under `noteit.ui.panes.*` that
-- only implements `setup`/`render` callbacks (see `ARCHITECTURE.md`) — panes
-- never touch another pane's buffer or window directly, or call
-- `noteit.ui.window`/the raw `nvim_*` window APIs themselves; they
-- coordinate only through the `ctx` table this module passes to their
-- callbacks.
-- @module noteit.ui.handler
local window = require("noteit.ui.window")

local M = {}

local session_id = 0

--- Open a floating window holding up to a 2x2 grid of panes.
-- @param opts table
--   `window_style`: frame sizing/spacing, see `noteit.ui.window.frame`.
--   `panes`: array of pane configs, each `{ type, col, row, width, height,
--     max_height, enter, focusable, hide_cursor, border, title }`:
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
--       - `hide_cursor` (boolean, default `false`): only meaningful on the
--         pane that sets `enter = true`. Minimizes the cursor (see
--         `noteit.ui.window.push_hidden_cursor`) for as long as this window
--         stays open. Other panes never receive real cursor focus (see
--         `focusable`), so this only needs to be set on the entered pane.
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
  local rects = window.compute_grid(window.frame(opts.window_style or {}), panes)

  -- Cursor hiding is a per-pane option (only meaningful on the `enter`
  -- pane; see `M.open`'s docs), not a whole-window one, so a window can
  -- freely mix panes that want it (e.g. an interactive list) with panes
  -- that don't.
  local should_hide_cursor = false
  for _, pane in ipairs(panes) do
    if pane.enter and pane.hide_cursor then
      should_hide_cursor = true
    end
  end

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
        window.set_lines(slot.buf, slot.win, lines, render_opts)
      end,
    }
  end

  --- Close one pane's window (its scratch buffer wipes itself via
  -- `bufhidden = wipe`, set by `window.set_lines`). Safe to call repeatedly.
  -- @local
  local function close_pane(index)
    local slot = slots[index]
    window.close(slot.win)
    slot.buf, slot.win = nil, nil
  end

  --- Create the pane's floating window/buffer and run its `setup` once.
  -- @local
  local function open_pane(index)
    local pane = panes[index]
    local buf = vim.api.nvim_create_buf(false, true)
    local win = window.open(buf, false, rects[index], pane, modules[index].style)
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

    if should_hide_cursor then
      window.pop_hidden_cursor()
    end

    for index in ipairs(panes) do
      close_pane(index)
    end

    pcall(vim.api.nvim_del_augroup_by_id, group)

    if opts.on_close then
      opts.on_close()
    end
  end

  if should_hide_cursor then
    window.push_hidden_cursor()
  end

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      rects = window.compute_grid(window.frame(opts.window_style or {}), panes)
      for index, pane in ipairs(panes) do
        window.update(slots[index].win, rects[index], pane, modules[index].style)
      end
      session.render()
    end,
  })

  session.render()

  return session
end

return M
