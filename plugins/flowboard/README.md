# Flow Board

A responsive board view for Markdown task boards such as `TODO.md`. It mirrors the desktop board's toolbar, lanes, card typography, card boxes and circular checkboxes. Lanes stay in file order and are packed into contiguous balanced columns: short lanes stack under longer ones, each column scrolls, and the columns share the available pane width.

The plugin edits the board's Markdown in place and preserves the lines it does not manage, so comments, blank lines, fenced code and card notes survive. It is not a live view: it reads the file when the block opens and when you choose **Reload from disk**, and it checks for external changes before every write.

## Features

- The native board's toolbar: file name and path, open/done counts, **Filter** search, **Hide done cards**, **Board/List** switch and the **Board menu**.
- Native lane headers: title, count beside the name, a quiet **New card at the top** button and a centered lane menu.
- Lane actions: **New card at the top**, **Lane menu**, **Add card** and **Add lane**.
- Native card typography (13 px) with 4 px gaps, card boxes and circular completion controls.
- Packed columns that preserve lane order, share the pane width and repack as the pane resizes; a single column fills the pane.
- Each board column scrolls inside the pane. The list view folds lanes and scrolls as one list.
- Card checkboxes move cards into the **Done** lane, as the native board does. A card completed in this session returns to its previous lane when unchecked and that lane still exists.
- A done lane that is not titled **Done** keeps a `<!-- flowboard:done -->` line under its heading, so the state survives a reload.
- Right-click a card for **Edit card**, **New card below**, one **Move to <lane>** row per other lane, and **Delete card**.
- Search filters cards (and hides empty lanes while filtering); hide done hides completed cards.
- Board menu: new card below, new lane, undo/redo, hide done, switch view, reload from disk, open as Markdown, reveal, copy path and close.
- Lane menu: new card, rename lane, new lane, move lane left/right, done lane and delete lane.
- `Ctrl+Z` / `Ctrl+Y` undo and redo board changes.
- Preserves comments, blank lines, fenced code, card continuation lines and the file's newline style.
- Detects an external edit before writing and offers **Reload from disk** or **Overwrite file on disk**.

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

When a write finds that the file changed since it was read, the board shows a conflict bar. **Reload from disk** discards the in-memory changes and reads the file again. **Overwrite** writes the current board over the file. The board does not watch the file, so use **Reload from disk** after editing it elsewhere.

Deleting a lane asks for a second click on **Confirm delete lane** and removes the lane's cards with it. The lane's other lines move to the previous lane, or to the top of the file when it is the first lane.

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
| Delete | Delete the selected card when the board has focus |
| Escape | Clear the selection or cancel editing |

## File format

Lanes are `## Title` headings and cards are `- [ ] text` or `- [x] text`. A lane titled **Done** is the done lane. Any other lane marked done in the plugin gets a `<!-- flowboard:done -->` line under its heading.

The plugin keeps every line it does not recognize. A comment, blank line or fenced block after a card travels with that card when the card moves; deleting a card leaves its following lines in place. Lines after a lane's last card belong to the lane, and deleting the lane moves them to the previous lane or the file preamble. The file's newline style and final newline are preserved.

Only the first line of a card is shown and editable. Indented checklists and other continuation lines under a card are preserved on disk but are not displayed in this view.

## Limitations

- This is a plugin block, not a replacement for the native board. The native board remains the default for `.md` files; use **Open with → Flow Board** or the palette commands.
- Pane width comes from the block's resize callback. Pane and window resizes repack the columns; during a live split drag while the Flow Board itself has focus Tern may defer the width update, and clicking another pane refreshes it. The window half also polls the pane's accessibility header as a fallback.
- External edits are detected when the board writes, not watched live. Use **Reload from disk** to pull them in.
- Card notes, subtasks, tags and due dates on continuation lines are preserved but not shown or editable here.
- Deleting a lane deletes every card in it. The second click on **Confirm delete lane** is the confirmation.
- Tern 0.9.21 drops nested submenus from right-click menus, so each destination is a top-level **Move to <lane>** row instead of a submenu.
- Tern's plugin UI exposes click, double-click and right-click actions but no pointer drag/drop events, so cards cannot be dragged between lanes in this block. Use a **Move to <lane>** row in a card's right-click menu; the native board still supports dragging.

## Development

```sh
tern plugin link plugins/flowboard
tern plugin reload
tern plugin list
```

The plugin has no build step and no external dependencies.
