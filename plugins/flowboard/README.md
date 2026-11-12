# Flow Board

A responsive board view for Markdown task boards such as `TODO.md`. It mirrors the desktop board's toolbar, lanes and cards, but its lanes use CSS flex-wrap, so they reflow into rows as the pane narrows instead of each lane taking a fixed full-height column.


## Features

- The native board's toolbar: file name and path, open/done counts, **Filter** search, **Hide done cards**, **Board/List** switch and the **Board menu**.
- Lanes with title, card count, **New card at the top**, **Lane menu**, **Add card** and **Add lane**.
- Card checkboxes move cards into the **Done** lane, as the native board does.
- Search filters cards (and hides empty lanes while filtering); hide done hides completed cards.
- Board menu: new card below, new lane, undo/redo, hide done, switch view, open as Markdown, reveal, copy path and close.
- Lane menu: new card, rename lane, new lane, move lane left/right, done lane and delete lane.
- `Ctrl+Z` / `Ctrl+Y` undo and redo board changes.
- Reads and writes the board's Markdown file in place, so the native board and this view stay in sync.

## Install

```sh
tern plugin link plugins/flowboard
tern plugin reload
```

The plugin declares `TODO.md`, `TASKS.md`, `BOARD.md` and `KANBAN.md`, so **Open with → Flow Board** appears for those files. The palette also has:

- **Flow Board: Open board** opens the focused/current board beside the focused pane.
- **Flow Board: Open board in a tab** opens it in a new tab.

## Usage

Open a Markdown board file with **Flow Board**, or run a palette command. Click a card's title to select it, click its checkbox to move it to the Done lane, and use the lane's **Lane menu** for lane actions. The filter field and the inline editors use Tern's native editing.

Keyboard:

| Key | Action |
| --- | --- |
| arrows | Move the card selection |
| Space | Toggle the selected card |
| Enter | Edit the selected card |
| `o` | New card below |
| `v` | Switch board/list view |
| Shift+X | Hide done cards |
| Ctrl+Z / Ctrl+Y | Undo / redo |
| Delete | Delete the selected card |
| Escape | Clear the selection or cancel editing |

## File format

Lanes are `## Title` headings and cards are `- [ ] text` or `- [x] text`. The plugin reads and rewrites those lines; other Markdown lines are not preserved by structural edits. Keep the file in the repository (or a backup) if it contains comments you need.

## Limitations

- This is a plugin block, not a replacement for the native board. The native board remains the default for `.md` files; use **Open with → Flow Board** or the palette commands.
- Tern plugin blocks report a fixed 80x24 cell grid, so the block cannot measure its pixel width from Lua. The lane layout therefore relies on CSS flex-wrap rather than computed masonry.
- Card notes, subtasks, tags and due dates are displayed as part of the card text; editing those details is not implemented yet.
- Drag and drop between lanes is not implemented; use the checkbox or the card/lane menus.

## Development

```sh
tern plugin link plugins/flowboard
tern plugin reload
tern plugin list
```

The plugin has no build step and no external dependencies.
