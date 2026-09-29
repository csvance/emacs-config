# Agent Manager for Emacs: Design

Status: phases 1 and 2 implemented and tested against a live campfire session (2026-09-28)
Scope: `lisp/agents.el` and its wiring in `init.el`, part of the personal Emacs configuration in `csvance/emacs-config`

## 1. Goals

Work with the Claude Code agents of one or more campfire sessions from Emacs, with each agent in its own buffer.

- Each agent is a full Emacs buffer running its native TUI, grouped under its project (ibuffer, `C-x p b`)
- A status pane directly below Treemacs, in the same column, shown and hidden with it (F8)
- See at a glance which agents are working, blocked or done, and jump to the next one that needs attention
- Start an agent in a project, and stop one, from a menu (F2)
- Agents on any campfire host look and behave the same
- Agents survive Emacs exiting or crashing; killing an agent buffer only detaches from it

### Non-goals

- Replacing herdr. A campfire session always has a herdr server, and people who do not use Emacs keep using herdr directly (`campfire`). Emacs is an optional, personal frontend over the same session
- Changing campfire for Emacs' sake. Everything here uses campfire's public commands
- A custom chat interface; agents always run in their native TUI inside vterm
- Auto-approving permission prompts; approvals stay manual

## 2. Concepts

**Host**: a machine running a campfire session, defined in `local.el`. Reached over SSH, or run directly when it is the local machine.

**Session**: the campfire session on a host: one sandbox, one herdr server, started with `campfire up`. It owns persistence; Emacs never starts or stops it.

**Agent**: a herdr pane in which herdr has detected a coding agent. Identified by host and pane ID (`w1:p1`). herdr also reports the agent's Claude session UUID, working directory, terminal title and status.

**Registry**: the in-Emacs table of known agents and their state; the single source of truth for every view.

## 3. Architecture

```
 Emacs                                        Host (campfire session)
 ┌──────────────────────────┐                 ┌─────────────────────────────────┐
 │ status pane / F2 /       │                 │ bwrap sandbox                   │
 │ ibuffer                  │  ssh (shared    │  └─ herdr server                │
 │        │                 │  connection)    │      ├─ pane w1:p1: claude      │
 │ registry ◄───────────────┼─ campfire events┤      ├─ pane w1:p2: claude      │
 │   (+ agent list polls)   │   (push)        │      └─ ...                     │
 │                          │                 │                                 │
 │ agent buffer (vterm) ◄───┼─ campfire herdr ┤  agent attach w1:p1             │
 │   one per agent          │   agent attach  │                                 │
 └──────────────────────────┘                 └─────────────────────────────────┘
```

Every call goes through `campfire herdr ARGS`, which runs one herdr CLI verb inside the session's sandbox with the profile campfire chooses, and status arrives through `campfire events`, a long-lived stream of the session's agent events. Emacs reaches into the sandbox; nothing inside can reach Emacs.

Verified against a live session (2026-09-28):

- `campfire herdr agent list` returns every agent with `agent_status` (`idle`, `working`, `blocked`, `done`, `unknown`), a `state_change_seq` counter, `cwd`, `terminal_title` and the Claude session UUID; about 0.5 s per call
- `campfire herdr agent attach PANE` shows just that agent's TUI, full screen, with no herdr chrome. Clicks, the wheel and keys work in vterm
- Killing the attaching process only detaches; the agent keeps running
- An Emacs buffer and a full herdr client can be attached to the same agent at once; input from either reaches it. The terminal has one size, set by whichever viewer resized last

## 4. Configuration

Hosts are declared in `local.el`:

```elisp
(setq agents-hosts
      '((:name "gpu" :ssh "user@gpu-host")))
```

| Key | Meaning |
|---|---|
| `:name` | Short name shown in the pane and buffer names |
| `:ssh` | SSH destination; omitted when the session runs on this machine |
| `:profile` | Sandbox profile (`HERDR_SANDBOX_PROFILE`); omitted to use the host's campfire profile. For tests and second sessions |
| `:campfire` | Command words that run campfire on the host, when it is not `campfire` on the PATH (for example a checkout's copy under test) |

Global options (defcustoms):

| Option | Default | Purpose |
|---|---|---|
| `agents-poll-interval` | `3` | Seconds between polls of a host whose event stream is down |
| `agents-stream-poll-interval` | `30` | Seconds between full refreshes while the stream is up (titles, anything an event missed) |
| `agents-pane-height` | `0.3` | Height of the status pane below Treemacs |
| `agents-command` | `"claude-sandbox"` | Command a new agent pane runs |

## 5. Transport

- One SSH connection per host, shared by every call through `ControlMaster`, with the control socket in `$XDG_RUNTIME_DIR` (local disk, not the NFS home)
- Polls and actions are asynchronous processes; a poll is skipped while the previous one for that host is still running
- Each host has one long-lived `campfire events` process. Every line is a JSON event: an agent's status change is applied to the registry at once, and anything else (a pane created, closed or with a newly detected agent, or the stream subscribing) triggers one full poll 0.3 s later
- While a host's stream is up, full polls drop to every 30 s; while it is down, polling runs every 3 s and the stream is restarted with backoff (2 s doubling to 60 s)
- Agent buffers run `ssh -t HOST campfire herdr agent attach PANE` in vterm, over the same shared connection
- A host whose calls fail shows its agents as `unknown` until a poll succeeds again

## 6. Paths and projects

Agents report paths as the sandbox sees them. `campfire info` gives the mapping as inside/outside pairs (today one: the checkout campfire was installed from, bound at `/campfire`); every other granted path is the same on both sides.

- Emacs reads each host's mapping once (retrying at most once a minute until it succeeds) and maps agents' directories to host paths
- An agent buffer's `default-directory` is the mapped path, so ibuffer-project and `C-x p b` group it with the project's files. This relies on the host's paths existing locally, which holds for a shared NFS home; elsewhere agents are still listed and usable, just not grouped under a local project
- Starting an agent maps the other way: the project root becomes the sandbox path passed to herdr as `--cwd`, which likewise assumes the project is at the same path on the host

## 7. Emacs side

### 7.1 Registry

A hash table keyed by host and pane ID. Each entry holds the host, pane, workspace, sandbox and mapped directories, status, change counter, title, Claude session UUID and buffer (if any). Every poll replaces a host's entries in one step and schedules one debounced redraw of all views.

### 7.2 Agent buffers

- Named `*agent: PROJECT (PANE)*`, which stays the same for the agent's life. The agent's terminal title (Claude sets it to the task) is shown in the status pane and the F2 menu, and the status in the buffer's mode line
- Visiting an agent switches to its buffer, creating it (a vterm running `agent attach`) when there is none
- Killing the buffer detaches; the agent keeps running. Stopping is a separate action that closes the pane, after confirmation
- When the attach process ends (the agent exited, or SSH dropped), the buffer closes; visiting the agent again reattaches

### 7.3 Status pane

- Buffer `*agents*` in a left side window, slot 1, directly below Treemacs (slot -1) and at the same width
- F8 (`agents-sidebar-toggle`) shows or hides Treemacs and the pane together; the startup hook uses it too
- Agents are grouped by project, the current project first; within a group blocked agents sort first and use the theme's warning face
- `RET` or a click visits the agent; `k` stops it, `g` refreshes
- Redraws follow polls, debounced; the pane never polls by itself

### 7.4 F2 menu

A Transient prefix, like the F1 menu, with descriptions computed when it opens:

| Group | Contents |
|---|---|
| Agents | Keys `1` to `9`: glyph, project, title and status |
| Actions | `a` next agent needing attention, `v` visit an agent, `n` new agent in the current project (`C-u` to pick the project), `k` stop an agent |
| View | `l` toggle the sidebar, `g` refresh |

### 7.5 Starting an agent

1. Map the project root to its sandbox path
2. Find the herdr workspace labelled with the project name, or create it with `workspace create --cwd PATH --label NAME`; otherwise add a tab to it with `tab create --workspace ID --cwd PATH`
3. `pane run PANE claude-sandbox`, then poll `agent list` about once a second, for up to a minute, until herdr detects the agent. `agent wait` cannot do this: it fails at once while the pane has no agent yet
4. Open its buffer

## 8. Security

- **No Emacs server access from sandboxes.** Emacs calls into the session; nothing in the sandbox is given a way to call Emacs
- **Strict parsing.** Responses are parsed as JSON; pane and workspace IDs must match `[A-Za-z0-9:_-]+` before they are used in a command, and remote commands are built from shell-quoted arguments
- **Hosts come from configuration only**; nothing received from a host changes where Emacs connects
- **No auto-approval** of permission prompts

## 9. Terminal details

Verified with Claude Code 2.1.283 (`"tui": "fullscreen"`) and herdr 0.9.1, each run from a shell with scrollback, full width and side by side:

- Both programs use the alternate screen and turn on mouse modes 1000, 1002 and 1003 with SGR encoding (1006). Emacs watches the output for these sequences and forwards the mouse only while a program has them on, so no per-buffer opt-in is needed and a plain shell keeps normal Emacs mouse behavior. `F1 M` turns forwarding off for one terminal
- Clicks (expand a Claude block, focus a herdr pane or workspace), drags (select text in Claude, resize a herdr split) and the wheel all work. Drag motion is reported while a button is held; hover motion (mode 1003 without a button) is not
- The terminal screen is the last N lines of the vterm buffer, followed by one empty line, and everything above is scrollback. Mouse rows are counted from the screen's first line, and columns from buffer text, so neither scrollback nor uneven glyph widths shift them
- Claude Code copies a mouse selection with OSC 52; vterm passes it to the kill ring and clipboard (`vterm-enable-manipulate-selection-data-by-osc52`), which also works for remote agents over SSH. herdr 0.9.1 itself forwards a pane's OSC 52 only to a full herdr client, never to `agent attach` (herdrdev/herdr#4612), so agent buffers get copies only from campfire's herdr build, which carries a patch for it (`tools/herdr/patches/` in campfire)
- Three display problems had to be fixed for TUIs to fit their window: line numbers took screen columns, symbols such as `⏺` and `⏵` fell back to fonts with taller lines (JuliaMono now draws them when installed, scaled to the default line height), and box-drawing glyphs on the cursor row made Emacs scroll one line, hiding the top row (`make-cursor-line-fully-visible` is off in terminals)
- `vterm-min-window-width` is lowered to 20 so side-by-side agent windows are not rendered 80 columns wide and cut off
- `C-g` is reserved for Emacs; `C-c C-g` sends it. Escape and Shift+Tab reach the program directly
- Clicking herdr's `+` in the tab bar has no effect even when the sequence is written straight to herdr; this is herdr behavior, not forwarding

## 10. Implementation phases

1. **Core**: hosts, transport, polling registry, agent buffers, status pane with the sidebar toggle, F2 menu, start and stop
2. **Push status** (done): `campfire events` streams herdr's `events.subscribe`. herdr answers one request per connection and reports status changes only to a subscription naming the pane, so the client renews its subscription whenever panes come or go. Measured: a status change reaches Emacs about a second after the agent's state changes, mostly herdr's own detection
3. **Persistence**: restore agent buffers at startup through desktop, reattaching on first visit
4. **Polish**: ibuffer status column, desktop notifications for blocked agents, resuming an exited agent from its Claude session UUID

Each phase is usable on its own.

## 11. Open questions

- **Several viewers**: whether Emacs should resize politely when herdr is attached to the same agent at a different size
- **Hosts without a shared home**: project grouping and starting agents assume the host's paths exist locally. TRAMP directories (`/ssh:HOST:PATH`) would lift that, at the cost of remote project detection
- **Stale detection**: whether a working agent with no status change for a long time should be flagged, and after how long
