--- Manages note storage, persistence, and extmark synchronization.
-- @module noteit.state
local M = {}

--- Replace a note array in place so existing module references remain valid.
-- @param notes table the note array to mutate in place
-- @param replacement table the notes to copy into `notes`
-- @local
local function replace_notes(notes, replacement)
  for key in pairs(notes) do
    notes[key] = nil
  end

  for index, note in ipairs(replacement) do
    notes[index] = note
  end
end

--- Create the note store and wire its persistence and buffer autocmds.
-- @param opts table dependencies: `augroup`, `namespace`, `get_config`, `on_change`
-- @return table the note state, exposing CRUD, sync, and persistence functions
function M.new(opts)
  local state = {
    notes = {},
  }
  local autocmds_registered = false

  --- Read the current plugin configuration from the owning module.
  -- @return table the active configuration
  -- @local
  local function config()
    return opts.get_config()
  end

  --- Notify consumers, such as an open note list, that notes changed.
  -- @local
  local function refresh()
    if opts.on_change then
      opts.on_change()
    end
  end

  --- Place or replace a note extmark in a source buffer.
  -- @param buf number the buffer to place the extmark in
  -- @param note table the note to attach an extmark to
  -- @local
  local function place_note(buf, note)
    local note_config = {
      virt_text = { { config().symbol, config().highlight } },
      virt_text_pos = "eol",
    }

    if note.note_id then
      note_config.id = note.note_id
    end

    note.note_id = vim.api.nvim_buf_set_extmark(buf, opts.namespace, note.lnum - 1, 0, note_config)
  end

  --- Update stored line numbers from extmarks in one buffer.
  -- @param buf number the buffer to synchronize notes against
  function state.sync_notes_for_buf(buf)
    local filename = vim.api.nvim_buf_get_name(buf)
    if filename == "" then
      return
    end

    for _, note in ipairs(state.notes) do
      if note.filename == filename and note.note_id then
        local pos = vim.api.nvim_buf_get_extmark_by_id(buf, opts.namespace, note.note_id, {})
        if pos and #pos > 0 then
          note.lnum = pos[1] + 1
        end
      end
    end
  end

  --- Synchronize extmark positions for every loaded buffer.
  function state.sync_all_loaded_notes()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        state.sync_notes_for_buf(buf)
      end
    end
  end

  --- Return a note filename relative to Neovim's current working directory.
  -- @param filename string the absolute filename to convert
  -- @return string the relative filename, or `filename` if it cannot be made relative
  function state.relative_note_filename(filename)
    return vim.fs.relpath(vim.fn.getcwd(), filename) or filename
  end

  --- Find the note attached to a filename and line number.
  -- @param filename string the note's filename
  -- @param lnum number the note's line number
  -- @return table|nil the matching note, if any
  function state.find_note(filename, lnum)
    for _, note in ipairs(state.notes) do
      if note.filename == filename and note.lnum == lnum then
        return note
      end
    end
  end

  --- Return the loaded buffer for a filename, if one exists.
  -- @param filename string the filename to look up
  -- @return number|nil the loaded buffer handle, if any
  function state.loaded_note_buffer(filename)
    local buf = vim.fn.bufnr(filename)
    if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
      return buf
    end
  end

  --- Create, persist, and publish a new note.
  -- @param buf number the buffer to place the note's extmark in
  -- @param filename string the note's filename
  -- @param lnum number the note's line number
  -- @param text string the note's text
  -- @return table the created note
  function state.create_note(buf, filename, lnum, text)
    local note = {
      filename = filename,
      lnum = lnum,
      note = text,
    }

    place_note(buf, note)
    table.insert(state.notes, note)
    state.save_notes()
    refresh()
    return note
  end

  --- Update a note, refresh its extmark, persist it, and publish the change.
  -- @param note table the note to update
  -- @param text string the note's new text
  -- @param buf number|nil the buffer holding the note's extmark, if loaded
  function state.update_note(note, text, buf)
    note.note = text

    local source_buf = buf or state.loaded_note_buffer(note.filename)
    if source_buf then
      place_note(source_buf, note)
    end

    state.save_notes()
    refresh()
  end

  --- Remove a note and its extmark, then persist and publish the change.
  -- @param note table the note to remove
  -- @param buf number|nil the buffer holding the note's extmark, if loaded
  function state.delete_note(note, buf)
    local source_buf = buf or state.loaded_note_buffer(note.filename)
    if source_buf then
      state.sync_notes_for_buf(source_buf)
    end

    if source_buf and note.note_id then
      vim.api.nvim_buf_del_extmark(source_buf, opts.namespace, note.note_id)
    end

    for i, candidate in ipairs(state.notes) do
      if candidate == note then
        table.remove(state.notes, i)
        break
      end
    end

    state.save_notes()
    refresh()
  end

  --- Register the autocmds that restore and synchronize notes.
  -- @local
  local function ensure_autocmds()
    if autocmds_registered then
      return
    end

    autocmds_registered = true

    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = opts.augroup,
      callback = function()
        if #state.notes == 0 then
          local dir = vim.fn.fnamemodify(config().notes_file, ":h")

          vim.fn.delete(config().notes_file)
          vim.fn.delete(dir, "d")
        end
      end,
    })

    vim.api.nvim_create_autocmd("BufReadPost", {
      group = opts.augroup,
      callback = function(ev)
        local bufname = vim.api.nvim_buf_get_name(ev.buf)
        for _, note in ipairs(state.notes) do
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
      group = opts.augroup,
      callback = function(ev)
        state.sync_notes_for_buf(ev.buf)
        state.save_notes()
      end,
    })
  end

  --- Synchronize loaded extmarks and write the notes JSON file.
  function state.save_notes()
    local dir = vim.fn.fnamemodify(config().notes_file, ":h")
    if vim.fn.mkdir(dir, "p") == 0 then
      vim.notify("Notes: failed to create directory " .. dir, vim.log.levels.ERROR)
      return
    end

    state.sync_all_loaded_notes()

    local json = vim.fn.json_encode(state.notes)
    local f, err = io.open(config().notes_file, "w")
    if f then
      f:write(json)
      f:close()
    else
      vim.notify("Notes: failed to save " .. config().notes_file .. " — " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  --- Register autocmds and load the notes JSON file into the store.
  function state.load_notes()
    ensure_autocmds()

    local f = io.open(config().notes_file, "r")
    if f then
      local content = f:read("*a")
      f:close()
      if content and #content > 0 then
        local ok, decoded = pcall(vim.fn.json_decode, content)
        if ok and type(decoded) == "table" then
          replace_notes(state.notes, decoded)
        else
          vim.notify("Notes: invalid JSON in " .. config().notes_file, vim.log.levels.ERROR)
          replace_notes(state.notes, {})
        end
      end
    end
  end

  return state
end

return M
