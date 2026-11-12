# Flow Board

A responsive board view for Markdown task boards such as `TODO.md`. It mirrors the desktop board's toolbar, lanes, card typography, card boxes and circular checkboxes. Lanes stay in file order and are packed into contiguous balanced columns: short lanes stack under longer ones, each column scrolls, and the columns share the available pane width.

## Features

- The native board's toolbar: file name and path, open/done counts, **Filter** search, **Hide done cards**, **Board/List** switch and the **Board menu**.
- Native lane headers: title, count beside the name, a quiet **New card at the top** button and a centered lane menu.
- Lane actions: **New card at the top**, **Lane menu**, **Add card** and **Add lane**.
- Native card typography (13 px) with 4 px gaps, card boxes and circular completion controls.
- Packed columns that preserve lane order, share the pane width and repack as the pane resizes; a single column fills the pane.
- Each column scrolls inside the pane instead of making the whole board grow.
- Card checkboxes move cards into the **Done** lane, as the native board does.
- Right-click a card for **Edit card**, **New card below**, **Move to lane** and **Delete card**.
- Search filters cards (and hides empty lanes while filtering); hide done hides completed cards.
- Board menu: new card below, new lane, undo/redo, hide done, switch view, open as Markdown, reveal, copy path and close.
- Lane menu: new card, rename lane, new lane, move lane left/right, done lane and delete lane.
- `Ctrl+Z` / `Ctrl+Y` undo and redo board changes.
- Reads and writes the board's Markdown file in place, so the native board and this view stay in sync.

## Layout

Lanes are packed into contiguous columns in file order. The plugin estimates each lane's height from its cards, then uses a balanced partition so short lanes fill the same column as longer ones. Without enough width for a full lane, the view falls back to one scrolling column. Columns use the available pane width, so a wide pane or a single pane expands the lanes instead of leaving fixed 272 px columns.

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
- Pane width comes from the block's resize callback. Pane and window resizes repack the columns; during a live split drag while the Flow Board itself has focus Tern may defer the width update, and clicking another pane refreshes it. The window half also polls the pane's accessibility header as a fallback.
- Card notes, subtasks, tags and due dates are displayed as part of the card text; editing those details is not implemented yet.
- Tern's plugin UI exposes click, double-click and right-click actions but no pointer drag/drop events, so cards cannot be dragged between lanes in this block. Use **Move to lane** in a card's right-click menu; the native board still supports dragging.

## Development

```sh
tern plugin link plugins/flowboard
tern plugin reload
tern plugin list
```

The plugin has no build step and no external dependencies.
