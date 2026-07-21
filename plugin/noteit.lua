if vim.g.loaded_noteit_nvim == 1 then
  return
end
vim.g.loaded_noteit_nvim = 1

local noteit = require("noteit")
noteit.setup()

vim.api.nvim_create_user_command("NoteAdd", noteit.add_note, {})
vim.api.nvim_create_user_command("NoteRemove", noteit.remove_note, {})
vim.api.nvim_create_user_command("NoteShow", noteit.show_note, {})
vim.api.nvim_create_user_command("NoteList", noteit.show_notes, {})
