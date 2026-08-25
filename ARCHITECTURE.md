# noteit.nvim UI architecture

This document describes the window/pane architecture used by the plugin's
floating-window UI (note list, note editor). It's aimed at anyone adding a
new pane type, a new window layout, or just trying to understand how the
pieces fit together.

This is a structural refactor of the plugin's original UI code; visual
styling and user-facing behavior are unchanged. If something here disagrees
with what you observe at runtime, that's a bug — please report it.

## The big idea

A single module, `lua/noteit/ui/handler.lua`, owns **all** window mechanics:
opening/closing/resizing floating windows, computing their layout, wiring
keymaps, and hiding the cursor. It is the only file that calls
`nvim_open_win`, `nvim_win_set_config`, or `nvim_win_close`.

Everything else is a **pane**: a small, self-contained Lua module under
`lua/noteit/ui/panes/` that implements at most two functions, `setup` and
`render`. A pane never touches another pane's buffer or window, and never
calls a low-level window API directly. Panes only talk to the handler
through a `ctx` table the handler passes to `setup`/`render`, and to each
other only through a shared, plain-Lua state table (`ctx.state`) and an
explicit action-dispatch mechanism (`ctx.dispatch`).

```
lua/noteit/
  init.lua                  -- composition root: builds actions + pane configs,
                              calls handler.open()
  state.lua                 -- note storage/persistence (unchanged)
  ui/
    handler.lua              -- the central handler
    panes/
      note_list.lua          -- interactive list of notes
      note_preview.lua        -- read-only preview of the selected note's text
      file_preview.lua        -- read-only preview of a note's source file/line
      note_editor.lua         -- writable buffer for creating/editing a note
```

## Windows, panes, and the grid

A "window" (as the term is used here) is one call to `handler.open()`. It
opens a single centered floating **frame** sized from `window_style`
(`width`/`height` as a fraction of the editor, plus `spacing`), and lays out
up to a **2x2 grid of panes** inside that frame — one per configured pane,
up to four.

The plugin currently opens two different kinds of windows:

- The **note list** window: a 2-pane or 3-pane layout — `note_list` (top
  left), optionally `note_preview` (bottom left), optionally `file_preview`
  (full-height right column).
- The **note editor** window: a 1 or 2-pane layout — `note_editor` (full
  height, left), optionally `file_preview` (full-height right column).

### Pane config schema

Each entry in `handler.open()`'s `panes` array is a plain table:

| field        | type             | default | meaning |
|--------------|------------------|---------|---------|
| `type`       | string, required | —       | pane module name under `noteit.ui.panes.*` |
| `col`        | `1`\|`2`         | `1`     | grid column |
| `row`        | `1`\|`2`, optional | —     | grid row within the column; **omit to span the column's full height** (only valid when this pane is the only one in its column) |
| `width`      | `0`-`1`, optional | —      | fraction of the frame's width for this pane's *column* |
| `height`     | `0`-`1`, optional | —      | fraction of the frame's height for this pane's *row* |
| `max_height` | rows, optional   | —       | caps this row's computed height at a fixed row count; see below |
| `enter`      | boolean          | `false` | focus this pane when the window opens; exactly one pane per window should set this |
| `focusable`  | boolean, optional | pane module's `style.focusable` (default `true`) | can this pane's window receive focus at all |
| `border`     | string, optional | pane module's `style.border` (default `"rounded"`) | override the floating window's border |
| `title`      | string, optional | pane module's `style.title` | override the floating window's title |

### Column/row sizing: "leftover" fractions

`width`/`height` are **fractions of the shared dimension**, not of the pane
itself: `width` sizes the whole *column* a pane belongs to (every pane in a
column shares its width), and `height` sizes the whole *row* within a
column. If nothing in a column sets `width`, that column gets whatever
fraction is left over after the other column's width (`1 - sum of explicit
fractions`); if more than one column is "auto" this way, they split the
leftover evenly. The same rule applies to rows within a column, using
`height`.

This is why, for example, the note-list window doesn't need `note_list` or
`note_preview` to specify a `width` at all — they simply take "whatever
column 1 ends up being", which is `1 - file_preview.width`.

### `max_height`: capping a row at a fixed size

Fractions alone can't express "this row should be exactly N rows tall,
regardless of the frame's size" — which is what the note-preview pane needs
(`config.note_preview_lines`). `max_height` (an absolute row count, not a
fraction) solves this: after a row's height is computed from fractions, any
row with `max_height` is clamped to `min(computed_height, max_height)`, and
the clamped-away space is handed back, split evenly, to sibling rows in the
same column that set **neither** `height` nor `max_height` (the "flexible"
rows — normally there is exactly one, e.g. `note_list` above a capped
`note_preview`).

In pathologically small terminals (frame height smaller than the sum of
every row's `max_height`), this can diverge slightly from a hypothetical
"exact" clamp-first algorithm — some rows may end up smaller than their
`max_height` even though clamping "shouldn't" apply. This is an intentional,
documented simplification: it only affects degenerate terminal sizes and
still produces a sane, non-overlapping layout.

### Full-column/row spanning

If a pane is the *only* pane in its column and doesn't set `row`, it spans
the column's full height (e.g. `file_preview` in both windows above). The
symmetric case — spanning a full row's width by omitting `col` — isn't
implemented; no current layout needs it, and it was left out to keep the
grid math simple. Add it to `compute_grid` in `handler.lua` if a future pane
needs it.

## The pane module contract

A pane module is a plain table:

```lua
-- lua/noteit/ui/panes/my_pane.lua
local M = {}

-- Optional: static defaults merged into this pane's nvim_open_win config
-- (used whenever the pane config itself doesn't override them).
M.style = {
  title = "My Pane",
  border = "rounded",
  focusable = false,
}

-- Called once, right after this pane's window/buffer is created (including
-- every time it's recreated after being hidden — see "pane lifecycle"
-- below). Use it for buffer options, local keymaps (via ctx.map), and
-- one-time autocmds (e.g. BufWriteCmd for a writable buffer).
function M.setup(ctx) ... end

-- Called whenever this pane should redraw: initial open, a sibling calling
-- ctx.render(), or a VimResized. Optional — a pane with genuinely static
-- content (like note_editor) can omit it entirely. Return `false` to ask
-- the handler to hide (fully close) this pane until a future render call
-- has content again.
function M.render(ctx) ... end

return M
```

### The `ctx` table

Both `setup` and `render` receive the same shape of `ctx`, scoped to that
one pane:

| field                      | purpose |
|----------------------------|---------|
| `ctx.buf`, `ctx.win`       | this pane's own buffer/window handles |
| `ctx.opts`                 | the `data` table passed to `handler.open()` — config, getter functions, etc. **Shared read-only by every pane in the window**; a pane should only read the fields it actually needs. |
| `ctx.state`                | the shared, mutable blackboard table for this window (see below) |
| `ctx.dispatch(name, ...)`  | invoke a named action from the `actions` table passed to `handler.open()`; errors if `name` isn't registered. The *only* sanctioned way a pane reaches outside its own window. |
| `ctx.render(pane_type?)`   | ask the handler to re-render one pane type (all panes of that `type`), or every pane if called with no argument |
| `ctx.map(modes, lhs, fn)`  | register a buffer-local keymap scoped to this pane's buffer |
| `ctx.close()`              | close the entire window (every pane in it) |
| `ctx.set_lines(lines, opts?)` | replace this pane's buffer contents; `opts` supports `readonly`, `filetype`, `wrap`, `linebreak`, `breakindent`, `namespace`, `highlights` |

### The shared `state` blackboard

`ctx.state` is one plain Lua table per window (`session.state` inside the
handler), shared by every pane in that window. It's how panes coordinate
without calling into each other: a pane that has something to say
(`note_list`, `note_editor`) writes to it; panes that care
(`note_preview`, `file_preview`) read from it.

Since `session.render()` (with no `pane_type` argument, e.g. the initial
render, or a `VimResized`) runs every pane's `render` **in array order**,
a pane that *publishes* state consumed by siblings must be listed **first**
in the window's `panes` array. Both `note_list.lua` and `note_editor.lua`
document this in their module comments — it's a convention, not something
the handler enforces.

`note_editor` is a special case: its published state (`ctx.state.note`,
the `{filename, lnum}` the editor was opened for) never changes for the
life of the window, so it's published once from `setup` rather than
`render` — `setup` always runs before any pane's first `render`, including
a sibling `file_preview`'s.

### Actions: the only way out

Anything a pane needs to do that reaches *outside* its own window —
opening a note's source file, deleting a note, persisting submitted note
text — is **not** implemented in the pane module. Instead, the pane calls
`ctx.dispatch("action_name", ...)`, and the window's caller (`init.lua`)
supplies an `actions` table mapping names to functions when it calls
`handler.open()`. This keeps pane modules pure UI (rendering + local
keymaps) and keeps all domain logic (note CRUD, navigating to a note's
source line) in `init.lua`, where it can be tested/reasoned about
independently of any window ever being open.

Currently registered actions:

- Note-list window: `goto_note(note)`, `delete_note(note)`.
- Note-editor window: `submit_note(text)`.

### Pane lifecycle: hide means fully closed

If `render` returns `false`, the handler tears the pane's window and
buffer down completely (`close_pane`) rather than merely hiding it. The
next time that pane needs to show something, the handler creates a fresh
buffer/window and runs `setup` again from scratch. This keeps the mental
model simple — "hidden" and "not currently existing" are the same state —
at the cost of re-running `setup` if a pane flickers hidden/shown rapidly
(not a concern for any current pane).

`note_preview` and `file_preview` both use this: they return `false`
whenever `ctx.state.note` is `nil` (or lacks a filename, for
`file_preview`), and reappear automatically once the sibling that
publishes `ctx.state.note` selects something showable again.

## Worked example: the note-list window

From `init.lua`'s `M.show_notes`:

```lua
local panes = {
  { type = "note_list", col = 1, row = 1, enter = true },
}
if M.config.list_note_preview then
  panes[#panes + 1] = {
    type = "note_preview",
    col = 1,
    row = 2,
    max_height = M.config.note_preview_lines,
  }
end
if M.config.file_preview then
  panes[#panes + 1] = {
    type = "file_preview",
    col = 2,
    width = preview_width_fraction(M.config.preview_split_ratio),
  }
end

active_note_list = handler.open({
  window_style = M.config.window_style,
  hide_cursor = true,
  panes = panes,
  data = {
    notes = function() return M.notes end,
    relative_filename = state.relative_note_filename,
    ui_namespace = ui_namespace,
    top_padding = vim.wo.scrolloff,
  },
  actions = {
    goto_note = goto_note,
    delete_note = M.remove_note,
  },
  on_close = function() active_note_list = nil end,
})
```

Flow: `note_list.render` reads `ctx.opts.notes()`, publishes the selected
note to `ctx.state.note`, and draws the list (closing the whole window via
`ctx.close()` if the list is empty). `note_preview.render` and
`file_preview.render` then run (later in the same array), read
`ctx.state.note`, and each either draw their content or hide (`return
false`) if there's nothing to show. `note_list`'s keymaps use
`ctx.dispatch("goto_note", ...)`/`ctx.dispatch("delete_note", ...)` for
anything outside the window, and `ctx.render()` (via a fresh `ctx.state`
write) to refresh siblings after moving the selection.

## Worked example: the note-editor window

From `init.lua`'s `open_note_editor`:

```lua
local panes = {
  { type = "note_editor", col = 1, enter = true },
}
if M.config.file_preview and preview and preview.filename ~= "" then
  panes[#panes + 1] = {
    type = "file_preview",
    col = 2,
    width = preview_width_fraction(M.config.preview_split_ratio),
  }
end

handler.open({
  window_style = M.config.window_style,
  hide_cursor = true,
  panes = panes,
  data = {
    initial_text = initial_text,
    preview = preview,
    ui_namespace = ui_namespace,
    top_padding = vim.wo.scrolloff,
  },
  actions = { submit_note = on_submit },
})
```

Flow: `note_editor.setup` makes the buffer writable (`buftype = acwrite`),
fills in `initial_text` if given, publishes `preview` to `ctx.state.note`
(read by the `file_preview` sibling, if present), and registers a
`BufWriteCmd` that calls `ctx.dispatch("submit_note", text)` on `:w`.
`note_editor` has no `render` — its content is fixed for the life of the
window. The window closes when the user leaves/closes the editor buffer
(`:q`/`:q!`), via the handler's generic "the `enter` pane's `BufWipeout`/
`BufWinLeave` closes the whole window" wiring — no bespoke close logic is
needed in the pane module.

## Cursor hiding

Ported unchanged (behaviorally) from the original `floating.lua`: while
`hide_cursor = true` and any pane in the window is open, the handler
shrinks the cursor to a near-invisible 1%-height hairline
(`guicursor` `hor1-...-blinkon0` for every mode) rather than trying to
recolor it — cursor *shape* is portable across terminals, cursor *color*
is not (VTE-based terminals like GNOME Terminal ignore OSC 12 color
requests entirely). Nested `push_hidden_cursor`/`pop_hidden_cursor` calls
are reference-counted so the original `guicursor` is restored exactly once
every window that requested hiding has closed.

## Known, deliberate simplifications vs. the original implementation

These were accepted trade-offs to keep the new code minimal; none change
user-visible behavior in practice:

- **No per-window file-lines cache.** The original note-list code cached a
  selected note's source file's lines across renders to avoid re-reading
  the same file repeatedly while navigating. `file_preview.lua` just
  re-reads the file on every render. Negligible perf impact for typical
  file sizes and navigation speed.
- **`max_height` clamp/reclaim vs. the original two-step split.** See
  "max_height" above — behaviorally identical except in pathologically
  small terminals.
- **No full-row-width spanning** (omitting `col`) — not implemented, since
  no current layout needs it (see "Full-column/row spanning" above).
