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
- Edit notes with an optional side-by-side file preview
- Browse notes with file and note previews

## :package: Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
return {
  "FredSkar/noteit.nvim",
  config = function()
    require("noteit").setup({
      symbol = "🔖",
      highlight = "Todo",
      file_preview = true,
      list_note_preview = false,
      preview_split_ratio = 0.5,
      window_style = {
        width = 0.9,
        height = 0.7,
        spacing = {
          horizontal = 3,
        },
      },
    })
  end,
}
```

## :wrench: Configuration
- `symbol` - The symbol to use for the note mark.
- `highlight` - The highlight group to use for the note mark (from Neovim [group names](https://neovim.io/doc/user/syntax/#group-name)). Use `Ignore` to disable highlighting.
- `notes_file` - The file to store the notes in. Defaults to a `noteit` folder under Neovim's data directory.
- `file_preview` - Show source-file previews in floating windows, positioned using the invoking editor's `scrolloff`. Defaults to `true`.
- `list_note_preview` - Show the selected note preview in `:NoteList`. Defaults to `true`.
- `preview_split_ratio` - The percentage of the floating layout width used by the file preview. Defaults to `0.6`.
- `window_style` - Set the full floating layout size scaling values. Defaults to a width and height of `0.8`.
- `window_style.spacing.horizontal` - Horizontal space between floating windows.
- `window_style.spacing.vertical` - Vertical space between stacked floating windows.

## :scroll: Usage
| Command | Default mapping | Description |
| --- | --- | --- |
| `:NoteAdd` | `<leader>na` | Add a note to the current line, or edit the selected note in `:NoteList`. |
| `:NoteRemove` | `<leader>nr` | Remove the note at the current line, or the selected note in `:NoteList`. |
| `:NoteShow` | `<leader>ns` | Edit the note at the current line, or the selected note in `:NoteList`. |
| `:NoteList` | `<leader>nl` | Open or refresh the project note list. |

In the note editor, use normal editing keys; `:w` and `:SaveNote` save the note. `:q` preserves Neovim's normal unsaved-buffer warning, while `:q!` closes the editor and its previews.

### Note List controls

- `j`, `<Down>`, or `<Tab>` - Select the next note.
- `k`, `<Up>`, or `<S-Tab>` - Select the previous note.
- `<CR>` - Open the selected note's file at its recorded line.
- `dd` - Remove the selected note.
- `<Esc>` or `:q` - Close the entire Note List layout.

The list displays each note as an ID, a filename relative to the current working directory, and its line number. It uses `Visual` to mark the selection. If no notes are available, `:NoteList` shows a warning instead of opening a window.
