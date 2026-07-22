local M = {}

-- Namespace for virtual text as the directiry where nvim was launched.
local path_hash = vim.fn.sha256(vim.fn.getcwd()):sub(1, 16)
local ns = vim.api.nvim_create_namespace(path_hash)
local augroup = vim.api.nvim_create_augroup("notes_" .. path_hash, { clear = true })

-- Default config
M.config = {
    symbol = "🔖",
    highlight = "Todo",
    notes_file = vim.fn.stdpath("data") .. "/noteit/" .. path_hash .. ".json",

    window_style = {
        width = 0.6,
        height = 0.2,
    },
}

-- Table to store notes
M.notes = {}

local function place_note(buf, note)
    local opts = {
        virt_text = { { M.config.symbol, M.config.highlight } },
        virt_text_pos = "eol",
    }

    if note.note_id then
        opts.id = note.note_id
    end

    local note_id = vim.api.nvim_buf_set_extmark(buf, ns, note.lnum - 1, 0, opts)
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
            local pos = vim.api.nvim_buf_get_extmark_by_id(buf, ns, note.note_id, {})
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

------------------------------------------------------------
-- Setup function for user configuration
------------------------------------------------------------
function M.setup(opts)
    M.config = vim.tbl_extend("force", M.config, opts or {})
    M.load_notes()
end

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

------------------------------------------------------------
-- Window for a note
------------------------------------------------------------
local function open_floating_window()
    local buf = vim.api.nvim_create_buf(false, true)

    local stats = vim.api.nvim_list_uis()[1]
    local width = math.floor(stats.width * M.config.window_style.width)
    local height = math.floor(stats.height * M.config.window_style.height)
    local row = math.floor((stats.height - height) / 2)
    local col = math.floor((stats.width - width) / 2)

    local opts = {
        relative = "editor",
        width = width,
        height = height,
        row = row,
        col = col,
        style = "minimal",
        border = "rounded",
        title = " Note ",
        title_pos = "center",
    }

    local win = vim.api.nvim_open_win(buf, true, opts)

    return buf, win
end

local function edit_in_floating_window(initial_text, on_submit)
    local float_buf, float_win = open_floating_window()

    if initial_text then
        vim.api.nvim_buf_set_lines(float_buf, 0, -1, false, { initial_text })
        vim.api.nvim_win_set_cursor(float_win, { 1, #initial_text })
    end

    vim.cmd(initial_text and "startinsert!" or "startinsert")

    vim.keymap.set("i", "<CR>", function()
        local lines = vim.api.nvim_buf_get_lines(float_buf, 0, -1, false)
        local text = table.concat(lines, " "):gsub("^%s*(.-)%s*$", "%1")

        vim.api.nvim_win_close(float_win, true)
        vim.cmd("stopinsert")
        on_submit(text)
    end, { buffer = float_buf, silent = true })

    vim.keymap.set({ "n", "i" }, "<Esc>", function()
        vim.api.nvim_win_close(float_win, true)
        vim.cmd("stopinsert")
    end, { buffer = float_buf, silent = true })
end

----------------------------------------------------------
-- Edit already existsing note
----------------------------------------------------------
function M.edit_note(note)
    local current_buf = vim.api.nvim_get_current_buf()
    edit_in_floating_window(note.note, function(updated_text)
        if updated_text ~= "" then
            -- Update reference properties
            note.note = updated_text
            note.text = M.config.symbol .. " " .. updated_text

            -- Redraw sign/extmark in the source buffer
            place_note(current_buf, note)
            M.save_notes()

            vim.cmd("redraw")
            vim.notify("Note updated", vim.log.levels.INFO)
        else
            if note.note_id then
                vim.api.nvim_buf_del_extmark(current_buf, ns, note.note_id)
            end

            for i, v in ipairs(M.notes) do
                if v == note then
                    table.remove(M.notes, i)
                    break
                end
            end

            M.save_notes()

            vim.cmd("redraw")
            vim.notify("Note deleted", vim.log.levels.INFO)
        end
    end)
end

------------------------------------------------------------
-- Add a note at current line
------------------------------------------------------------
function M.add_note()
    local buf = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(buf)
    local line = vim.api.nvim_win_get_cursor(0)[1]

    sync_notes_for_buf(buf)

    -- Check if note already exists
    for _, note in ipairs(M.notes) do
        if note.filename == file and note.lnum == line then
            M.edit_note(note)
            return
        end
    end

    edit_in_floating_window(nil, function(note)
        if note ~= "" then
            -- Save note
            local note_text = M.config.symbol .. " " .. note
            local tmp_note = { filename = file, lnum = line, text = note_text, note = note }
            place_note(buf, tmp_note)
            table.insert(M.notes, tmp_note)

            M.save_notes()

            vim.cmd("redraw")
            vim.notify("Note added", vim.log.levels.INFO)
        end
    end)
end

------------------------------------------------------------
-- Remove note from current line
------------------------------------------------------------
function M.remove_note()
    local buf = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(buf)
    local line = vim.api.nvim_win_get_cursor(0)[1]

    sync_notes_for_buf(buf)

    for i, note in ipairs(M.notes) do
        if note.filename == file and note.lnum == line then
            table.remove(M.notes, i)
            vim.api.nvim_buf_clear_namespace(buf, ns, line - 1, line)
            break
        end
    end

    M.save_notes()
end

------------------------------------------------------------
-- Show note for note at current line
------------------------------------------------------------
function M.show_note()
    local buf = vim.api.nvim_get_current_buf()
    local file = vim.api.nvim_buf_get_name(buf)
    local line = vim.api.nvim_win_get_cursor(0)[1]

    sync_notes_for_buf(buf)

    for _, note in ipairs(M.notes) do
        if note.filename == file and note.lnum == line then
            local current_note = note.note or ""
            vim.ui.input({ prompt = "Note: ", default = current_note }, function(new_note)
                if new_note then
                    note.note = new_note
                    note.text = M.config.symbol .. " " .. (new_note ~= "" and new_note or "Note")
                    M.save_notes()
                    vim.notify("Note updated", vim.log.levels.INFO)
                end
            end)
            return
        end
    end

    vim.notify("No note at current line", vim.log.levels.WARN)
end

------------------------------------------------------------
-- Show notes in quickfix
------------------------------------------------------------
function M.show_notes()
    vim.fn.setqflist(M.notes)
    vim.cmd("copen")
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
    local f = io.open(M.config.notes_file, "r")
    if f then
        local content = f:read("*a")
        f:close()
        if content and #content > 0 then
            M.notes = vim.fn.json_decode(content)
        end
    end

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

return M
