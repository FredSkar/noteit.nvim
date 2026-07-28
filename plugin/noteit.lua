if vim.g.loaded_noteit_nvim == 1 then
  return
end
vim.g.loaded_noteit_nvim = 1

local noteit = require("noteit")

vim.api.nvim_create_user_command("NoteAdd", noteit.add_note, {})
vim.api.nvim_create_user_command("NoteRemove", noteit.remove_note, {})
vim.api.nvim_create_user_command("NoteShow", noteit.show_note, {})
vim.api.nvim_create_user_command("NoteList", noteit.show_notes, {})

vim.keymap.set("n", "<leader>na", "<cmd>NoteAdd<CR>", { desc = "Add note", silent = true })
vim.keymap.set("n", "<leader>nl", "<cmd>NoteList<CR>", { desc = "List notes", silent = true })
vim.keymap.set("n", "<leader>ns", "<cmd>NoteShow<CR>", { desc = "Show note", silent = true })
vim.keymap.set("n", "<leader>nr", "<cmd>NoteRemove<CR>", { desc = "Remove note", silent = true })
