# :notebook_with_decorative_cover: `noteit.nvim`
**noteit.nvim** is a small Neovim plugin to add and keep track of virtual notes in a project.
Do you always read a chunk of code and then forget 5 minutes later what it did?
**noteit** can be used to add small notes pinned in the code to help you remember stuff. It just adds
a small visuall mark on the line where the note was added so it doesn't get in the way of the code itself.
This are just an early beta, so bugs are included.

## :bell: Features
- Add notes to your code with a simple command.
- Notes are handled per "project"
- Jump to notes
- View all notes in a project

## :package: Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  "FredSkar/noteit.nvim",
  config = function()
    require("noteit").setup({
      symbol = "🔖",
      highlight = "Todo",
      window_style = {
        width = 0.6,
        height = 0.2,
      },
    })
  end,
}
```

## :wrench: Configuration
- `symbol` - The symbol to use for the note mark.
- `highlight` - The highlight group to use for the note mark (from Neovim [group names](https://neovim.io/doc/user/syntax/#group-name)). Use `Ignore` to disable highlighting.
- `notes_file` - The file to store the notes in. Defaults to a `noteit` folder under Neovim's data directory.
- `window_style`- Set the floating window style scaling value.

## :scroll: Usage
- `:NoteAdd` - Add a note to the current line.
- `:NoteRemove` - Remove the note from the current line.
- `:NoteShow` - Show the note for the current line.
- `:NoteList` - List all notes in the current project.
