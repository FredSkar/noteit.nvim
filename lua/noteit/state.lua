local M = {}

local function replace_notes(notes, replacement)
  for key in pairs(notes) do
    notes[key] = nil
  end

  for index, note in ipairs(replacement) do
    notes[index] = note
  end
end

function M.new(opts)
  local state = {
    notes = {},
  }
  local autocmds_registered = false

  local function config()
    return opts.get_config()
  end

  local function refresh()
    if opts.on_change then
      opts.on_change()
    end
  end

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

  function state.sync_all_loaded_notes()
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        state.sync_notes_for_buf(buf)
      end
    end
  end

  function state.relative_note_filename(filename)
    return vim.fs.relpath(vim.fn.getcwd(), filename) or filename
  end

  function state.find_note(filename, lnum)
    for _, note in ipairs(state.notes) do
      if note.filename == filename and note.lnum == lnum then
        return note
      end
    end
  end

  function state.loaded_note_buffer(filename)
    local buf = vim.fn.bufnr(filename)
    if buf > 0 and vim.api.nvim_buf_is_loaded(buf) then
      return buf
    end
  end

  function state.create_note(buf, filename, lnum, text)
    local note = {
      filename = filename,
      lnum = lnum,
      text = config().symbol .. " " .. text,
      note = text,
    }

    place_note(buf, note)
    table.insert(state.notes, note)
    state.save_notes()
    refresh()
    return note
  end

  function state.update_note(note, text, buf)
    note.note = text
    note.text = config().symbol .. " " .. text

    local source_buf = buf or state.loaded_note_buffer(note.filename)
    if source_buf then
      place_note(source_buf, note)
    end

    state.save_notes()
    refresh()
  end

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
