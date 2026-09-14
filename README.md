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
- **Update notifier + update buttons** for git-managed third-party plugins:
  - On load (and on refresh) each git-backed plugin is compared against its
    `origin` (a `git fetch` plus a fast-forward check, so the verdict matches
    what `omarchy plugin update` can actually do); a cleanly updatable
    checkout is marked "update available"
  - An accent dot appears on the bar button, a summary line in the panel
    header ("N updates available"), and **Update all** buttons in the header
    and footer, plus an **Update** button on each stale row
  - When a checkout cannot fast-forward — uncommitted local changes or
    unpublished commits — no update is offered and the row meta says why
    ("no update · local changes" / "no update · unpublished commits")
  - Row actions share one update process, so per-row actions and "update all"
    can never run over each other
  - Row meta shows the installed commit (`@abc1234`), and in-menu notices
    reflect the command's real exit code (success vs failed), so you can
    verify that an update actually landed
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
| `r`      | Refresh              |
| `Esc`    | Close                |

## Files

- `PluginManager.qml` — bar widget + popup panel
- `PluginManager.js` — data model (lists plugins via the Omarchy CLI)
- `manifest.json` — plugin manifest

The widget shells out to `omarchy plugin list --json`, `omarchy-plugin-catalog`,
and the `omarchy plugin …` commands, so it always reflects reality.

To update git-managed plugins from a terminal instead:
`omarchy plugin update <id>` (or `omarchy plugin update` for all of them).