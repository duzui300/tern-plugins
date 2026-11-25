# Agent Sessions

A Tern canvas that turns the agent histories already on your machine into one searchable, resumable list.

<p align="center">
  <img src="docs/session-manager.png" alt="Agent Sessions list" height="460" />
  &nbsp;&nbsp;
  <img src="docs/session-detail.png" alt="Session detail" height="460" />
</p>

Claude Code, Antigravity, Pi, omp and Carly each keep conversations in their own format and directory. Finding the one you want means remembering which tool, which project and which UUID. This plugin reads those stores, groups the sessions by agent, folder or tag, and resumes one with a click when the agent supports it.

## Features

- Five adapters: Claude Code, Antigravity (IDE and CLI), Pi, omp and Carly.
- Group by agent, folder or tag; filter by folder or tag; search titles, paths and tags.
- Collapsible groups, collapsed by default, with expand-all/collapse-all.
- Paged list: 80 rows per page with Previous/Next, so expanding a large history stays inside Tern's canvas limit.
- Filter chips show the active folder, tag and search, with one Clear filters action.
- Resume in a new Tern tab with the agent's own command, or copy the command; Claude Code and Antigravity resume with `--dangerously-skip-permissions` and omp with `--approval-mode=yolo`, so a resumed session does not stop at permission prompts.
- Carly sessions cannot be resumed here; search, rename, tag, read, copy the path and delete them. Copy path puts the JSONL on the clipboard so another agent can continue the conversation.
- Aliases and tags live in the plugin's own SQLite database. Session files are never written.
- Hide noisy sessions, or delete one session from disk behind a two-step confirmation.
- Select several sessions and delete them together, with the same permanent-delete confirmation.
- Responsive layout: rows wrap and the action column stays aligned when the pane narrows.

## Where sessions come from

| Agent | Session files | Resume command |
| --- | --- | --- |
| Claude Code | `~/.claude/projects/<project>/<id>.jsonl` | `claude --resume <id> --dangerously-skip-permissions` |
| Antigravity | `~/.gemini/antigravity{,-cli}/conversation_summaries.db`, plus `brain/<id>/.system_generated/logs/transcript_full.jsonl` (IDE transcripts are chunked under `chunks/transcript_full/`) | `agy --conversation <id> --dangerously-skip-permissions` |
| Pi | `~/.pi/agent/sessions/<project>/<time>_<id>.jsonl` | `pi --session <id>` |
| omp | `~/.omp/agent/sessions/<project>/<time>_<id>.jsonl` | `omp --resume <id> --approval-mode=yolo` |
| Carly | `%LOCALAPPDATA%\Tern\carly\main\sessions\<time>_<id>.jsonl` on Windows; `~/Library/Application Support/Tern/...` on macOS; `~/.local/share/Tern/...` on Linux | — (read-only) |

The plugin never writes to these files. Antigravity data is opened read-only through `node:sqlite`.

## Install

```sh
tern plugin install github.com/duzui300/tern-plugins/plugins/agent-sessions
```

Or from a checkout:

```sh
tern plugin link plugins/agent-sessions
tern plugin reload
```

Requires Tern 0.9+ and Node.js 22.13+ (or 23.4+) for the built-in `node:sqlite` module. Without it the plugin still lists sessions, but tags and hidden state are unavailable and it shows a warning.

## Use

Run **Agent sessions** from the palette (`plugin.agent-sessions.open`).

- **Toolbar**: filter by folder or tag, search, switch grouping (agent, folder, tag), expand/collapse all, show hidden sessions, rescan. Active filters appear as chips with a Clear filters action.
- **Paging**: when the list is larger than 80 entries, Previous/Next page controls appear above the list. The status line shows the page number.
- **Groups**: collapsed by default. Click a group header to expand or collapse it; the badge counts its sessions.
- **Rows**: click a title to read the transcript. The icon buttons resume, copy the resume command, rename, edit tags, or hide/delete; rows without a resume command copy the transcript path instead.
- **Select**: the toolbar's **Select** button enters batch mode; each row gets a checkbox, clicking a title toggles it, and **Select all** picks every session matching the current filter, including other pages and collapsed groups. **Delete selected…** asks once more, then removes those sessions from disk.
- **Detail**: Back, Resume, Copy, Copy path, Rename, Tags; the transcript renders as Markdown. Copy path is available for every agent. Transcripts over 160 KB are truncated in the detail view with a note to use Copy path.

### Aliases and tags

Stored in `<Tern state>/plugin-data/agent-sessions/tags.db`, keyed by `agent` and session id. They never touch the session files and do not appear in the agents' own pickers.

- **Rename** changes the display name only.
- **Tags** edits a comma-separated list; tags show as badges in the list and can be used as the grouping key or a filter.

### Hide and delete

- **Hide from this list** keeps the files. The eye button shows hidden sessions again, where they can be restored.
- **Delete from disk...** asks once more, then removes the agent's files for that session: the JSONL and its companion directory for Claude/omp/Carly, the JSONL for Pi, or the conversation database, brain folder and summary rows for Antigravity. This cannot be undone, and the agent must not be using the session. In batch mode the same confirmation names the count and deletes each selected session in turn, reporting cleanup warnings separately from failures.

## How it works

The plugin is a window-half Tern plugin. `window.luau` draws a `tern.canvas` panel and handles actions; file and SQLite work runs in small Node helpers through `tern.process.run`:

- `scan.js` walks the five stores and prints a JSON array of `{agent, id, title, cwd, path, time}`. It reads a bounded head of each file and falls back to a full read only for small Claude sessions without a title, so a large history does not read every transcript in full. Sessions without a title are listed as untitled instead of being dropped. User content stored as an array of blocks (images, attachments) is read for its text blocks.
- `transcript.js` renders one session to Markdown (`--agent`, `--path`, `--id`). User content arrays are read the same way, and output is capped at 160 KB to stay inside the canvas limit.
- `tags.js` manages the SQLite sidecar for aliases, tags and hidden sessions (`get`, `set`, `hidden`, `hide`, `unhide`).
- `delete.js` removes one session's files after confirmation and reports cleanup warnings separately from failures.

To develop, link the directory and reload:

```sh
tern plugin link plugins/agent-sessions
tern plugin reload
```

Editing `window.luau` needs a reload; the Node helpers are read on the next scan or action.

## Limitations

- Session formats are the agents' own, not public APIs. A format change can break an adapter. Parsers tolerate missing fields and skip unreadable files.
- Antigravity conversations without a transcript show their summary title and no messages.
- The detail view truncates a transcript after 160 KB to stay inside Tern's canvas limit. Use Copy path to read the whole file.
- Lists are paged at 80 entries. Select all still applies to every session matching the current filter, not just the visible page.
- Without a Node build that provides `node:sqlite`, Antigravity sessions are not listed and tags and hidden state do not persist. The plugin shows a warning.
- If `agents.auto_acp` intercepts `claude` or `agy`, `--resume` may not pass through. Add the id to `agents.keep_tui`, or use Copy, to resume in the native interface.
- omp companion files without `.jsonl` are not listed; some are access-restricted while omp is running.
- Carly keeps one JSONL per conversation under Tern's own data directory; deleting the conversation that is currently open can fail on Windows while the chat holds the file.

## License

MIT. See the repository [LICENSE](../../LICENSE).
