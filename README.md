# Plugin Manager

A simple Omarchy shell bar widget for managing installed plugins.

## Install

```sh
omarchy plugin add https://github.com/davidmessenger123/omarchy-plugin-manager.git --enable
```

The bar asks where to place the icon; `omarchy bar move davidjm.plugin-manager -s right`
moves it afterwards if you change your mind.

## Features

- **Enable / Disable** any plugin whose state can be toggled (`omarchy plugin enable` / `disable`)
- **Uninstall** third-party plugins (`omarchy plugin remove`)
- **Configure** plugins that have editable settings:
  - First-party bar widgets open `~/.config/omarchy/shell.json`
  - Third-party plugins open their plugin folder for editing
- **Explicit, bounded update checks** for git-managed third-party plugins:
  - The **Check for updates** action explicitly opts into comparing git-backed plugins against `origin`; it performs a bounded, timed fetch and fast-forward check, and a cleanly updatable checkout is marked "update available"
  - An accent dot appears on the bar button, a summary line in the panel
    header ("N updates available"), and **Update all** buttons in the header
    and footer, plus an **Update** button on each stale row
  - When a checkout cannot fast-forward — uncommitted local changes or
    unpublished commits — no update is offered and the row meta says why
    ("no update · local changes" / "no update · unpublished commits")
  - Per-row updates use a bounded process; **Update all** launches `omarchy plugin update --yes` independently so the shell reload triggered by the first updated plugin cannot interrupt the remaining updates
  - Git checks and per-row updates use a system-owned Git binary, reject repository-controlled config/hooks, and fetch only a validated direct HTTPS remote
  - Row meta shows the installed commit (`@abc1234`), and per-row in-menu
    notices reflect the command's real exit code (success vs failed), so you
    can verify that an update actually landed
- **Marketplace** shortcut to https://plugins.omarchy.org/

## Keys

| Key      | Action               |
|----------|----------------------|
| `/`      | Focus search         |
| `↑` / `↓`| Move cursor          |
| `↵`/`Space` | Toggle selected   |
| `c`      | Configure selected   |
| `u`      | Update selected      |
| `Del`    | Uninstall selected   |
| `m`      | Open marketplace     |
| `r`      | Refresh installed/catalog data |
| update button | Explicitly check git updates |
| `Esc`    | Close                |

## Files

- `PluginManager.qml` — bar widget + popup panel
- `PluginManager.js` — data model (lists plugins via the Omarchy CLI)
- `git_check.py` / `git_update.py` — isolated Git status/update helpers
- `bounded_exec.py` — bounded fixed-command bridge
- `manifest.json` — plugin manifest

The widget uses fixed system command paths and bounded bridges for catalog
reads and per-row actions. Git-backed per-row updates run through
`git_update.py`, which validates the origin URL and disables
repository-controlled Git configuration. **Update all** delegates to
`omarchy plugin update --yes`.

To update git-managed plugins from a terminal instead:
`omarchy plugin update <id>` (or `omarchy plugin update` for all of them).
