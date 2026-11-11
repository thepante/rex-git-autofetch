# rex-git-autofetch

Fetch the git repositories open in [Rex](https://www.superlogical.com/rex) terminals, so your
branch status reflects the remote without running `git fetch`.

This is the Rex counterpart of
[tmux-git-autofetch](https://github.com/thepante/tmux-git-autofetch). It keeps the same idea and
drops the pieces tmux needed: there is no cron entry and no shell hook. The Rex server starts a
small Lua watcher that reads the directory of every terminal pane and fetches each repository at
most once every few minutes.

## Requirements

- Rex with the Lua script API: `rex do`, `rex.every`, `rex.on`, and `rex.exec`. Run
  `rex do -e 'return type(rex.every)'` and expect `"function"`.
- `git` in the server's `PATH`, or set `git` to its absolute path.
- For private repositories, the SSH key must be available to the Rex server. The watcher runs as
  the server, not as the shell you type in.

## Install

Clone the repository beside the rest of your Rex configuration:

```sh
git clone https://github.com/thepante/rex-git-autofetch ~/.config/rex/rex-git-autofetch
```

When `XDG_CONFIG_HOME` is set, clone it under `$XDG_CONFIG_HOME/rex/rex-git-autofetch` instead.

Add the plugin to `~/.config/rex/init.lua`:

```lua
require("rex-git-autofetch").setup()
```

Reload the configuration and check that the watcher started:

```sh
rex config reload
rex do git_autofetch_status
```

The status reports `running: true`, the watcher's PID, and the repositories it tracks. It fetches
them on the first scan; open tabs keep updating from then on.

## Configuration

Pass a table to `setup`. Every option is optional.

| Option | Default | Description |
| --- | --- | --- |
| `enabled` | `true` | Set to `false` to stop the watcher. |
| `frequency` | `3` | Minutes between fetches of the same repository. `0` fetches on every scan. |
| `scan_interval` | `60` | Seconds between scans of the open terminals. |
| `timeout` | `10` | Seconds a single `git fetch` may run before Rex stops it. Raise it for a repository whose fetch needs longer. |
| `git` | `"git"` | Name or absolute path of the git program. |
| `ssh_command` | none | Value for `GIT_SSH_COMMAND`, such as `"ssh -o BatchMode=yes"`. |
| `scan_paths` | none | Only fetch panes whose directory matches one of these patterns. |
| `skip_paths` | none | Never fetch panes whose directory matches one of these patterns. |
| `log` | `false` | Append fetches, errors, and scan summaries to `git-autofetch.log` in the state directory. The log rotates to `git-autofetch.log.1` at 1 MB. |
| `state_dir` | `~/.local/state/rex-git-autofetch` | Where the watcher keeps its PID, state, and log. |

For example:

```lua
require("rex-git-autofetch").setup({
  frequency = 5,
  scan_paths = {
    "^~/Projects/",
    "/probandoski/",
  },
  skip_paths = "/vendor/",
  log = true,
})
```

### Path matching

`scan_paths` and `skip_paths` match the working directory of the pane, not the root of the
repository that directory belongs to. Each entry is plain text:

- A `^` at the start anchors the match to the start of the path.
- A `$` at the end anchors it to the end.
- A `~` at the start, or right after `^`, expands to your home directory.
- A pattern that ends in `/` matches that directory and every path under it.
- `skip_paths` wins over `scan_paths`: a path allowed by one pattern is still skipped when another
  pattern in `skip_paths` matches it.

Patterns are plain text, not regular expressions. Write one entry per path:

```lua
scan_paths = { "/work/", "/clients/" }
```

To match a whole tree, anchor the front: `"^~/Projects/"` matches `~/Projects` and every path
under it, and nothing else.

A path that matches no `scan_paths` entry is ignored. When `scan_paths` is unset, every pane is
eligible.

**Caution:** Set `scan_paths` to the directories you trust. `git fetch` runs the commands that a
repository's own configuration names, such as `core.sshCommand`. When `scan_paths` is unset, the
watcher runs them for every repository you enter, including one unpacked from an archive.

## Actions

The plugin defines two actions:

| Action | Description |
| --- | --- |
| `git_autofetch_status` | Report whether the watcher runs, its PID, and the repositories it fetched. |
| `git_autofetch_start` | Start the watcher when it is not running. |

Run them from the command line:

```sh
rex do git_autofetch_status
```

The status reports `stale: true` when the watcher runs but its last scan is older than three scan
intervals.

Bind them in `init.lua` if you want a key:

```lua
rex.bind("prefix/g", "git_autofetch_status")
```

## How it works

`setup` starts `rex do --all` with this file as a detached process. The watcher runs a timer every
`scan_interval` seconds:

1. Lists every session and its terminal blocks.
2. Reads the foreground directory of each local terminal.
3. Resolves each directory to its git common directory, so a repository and all its worktrees
   count as one.
4. Runs `git fetch --quiet --all` once per repository, at most every `frequency` minutes.

A repository whose fetch fails waits twice as long after each failure in a row, up to eight times
`frequency`. The next fetch that works resets the wait.

It also listens for `terminal.pwd_changed` and schedules a scan two seconds later. That event only
fires for shells that report their working directory, so the timer is the reliable path.

Only local blocks are scanned. A block that runs on another Rex host has paths the local server
cannot see.

The watcher only fetches: it does not pull, and it does not display the result. Use your shell
prompt or a status tool to show the branch state.

The watcher stops when the Rex server stops, and `rex config reload` restarts it when this
configuration changes. A watcher that was replaced, or whose state directory was removed, stops
on its next scan. `rex config check` reports a bad option; fix it before reloading, or the
watcher stays stopped.

## Troubleshooting

**No repositories in the status.** The watcher only scans terminals that exist when a scan runs.
`rex do git_autofetch_status` shows `running: true` and an empty `repos` list when no pane matches
`scan_paths`.

**The watcher does not start.** Run `rex config check` and look for an error from
`rex-git-autofetch`. If the module is not found, the clone is not in the configuration directory
that Rex reads.

**Authentication fails.** The watcher runs as the Rex server. Make sure the server can reach the
same SSH agent and keys as your shell. On macOS the server usually inherits `SSH_AUTH_SOCK`; when
it does not, set `ssh_command` to a command that uses the key you want, or use an HTTPS remote
with a credential helper.

**A fetch times out.** The status shows `timed out after 10 seconds` for the repository. A fetch
that Rex stops starts over on the next try, so raise `timeout` when a repository needs longer.

**`git` is not found.** Set `git` to the absolute path, such as
`"/opt/homebrew/bin/git"`. This helps when the server starts with a minimal `PATH`.

**See what the watcher did.** Set `log = true`, reload, and read
`~/.local/state/rex-git-autofetch/git-autofetch.log`. The status also reports the last error for
each repository.

## Uninstall

1. Set `enabled = false` in `init.lua` and run `rex config reload`, or kill the PID that
   `git_autofetch_status` reports.
2. Remove the `require("rex-git-autofetch").setup(...)` call from `init.lua`.
3. Run `rex config reload` again.
4. Delete `~/.config/rex/rex-git-autofetch` and `~/.local/state/rex-git-autofetch`.

## Differences from tmux-git-autofetch

- No cron entry and no `~/.zshrc` hook. The watcher is a Rex Lua script, so it starts and stops
  with the server.
- Configuration lives in `init.lua` instead of tmux options.
- Worktrees of one repository share a single fetch, because the watcher keys repositories by
  `git-common-dir`; the tmux plugin treats each worktree as its own repository.
- Failures are visible in `state.json` and the optional log instead of `/tmp`.
