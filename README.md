# monitorctl

A local macOS CLI for monitor scaling, resolution, refresh rate, safe previews,
and display-mode profiles. Built for humans and coding agents, with stable
display selectors and JSON output.

```sh
monitorctl list
monitorctl modes --hidpi
monitorctl scale 250
monitorctl undo
```

## Install

```sh
git clone https://github.com/EricWay1024/monitorctl.git
cd monitorctl
python3 install.py
```

The installer copies the self-contained Ruby application to
`~/Library/Application Support/monitorctl/app`, creates
`/usr/local/bin/monitorctl`, and installs the included
[`monitor-control` skill](skill/SKILL.md). It adds a conditional discovery note
to your Codex global instructions while preserving existing content.

Creating the global command may show macOS's administrator authentication
dialog. Runtime mode changes do not require administrator privileges.

Requirements: macOS, its bundled Ruby runtime, Python 3 for installation, and
a logged-in graphical session for display operations. There are no third-party
runtime packages, paid applications, or network services.

To inspect the source without installing:

```sh
ruby monitorctl --help
ruby monitorctl list --json
```

## Select a monitor

The default display is `main`. Select another display by its stable UUID,
current numeric ID, or an unambiguous part of its name. `external` selects
the external display when exactly one matches.

```sh
monitorctl list --json
monitorctl modes --display external --hidpi
monitorctl scale 250 --display DISPLAY_UUID --json
monitorctl resolution 1024x640 --display DISPLAY_UUID
monitorctl refresh 60 --display DISPLAY_UUID
```

Use UUIDs for automation: numeric IDs can change after a reconnect. Duplicate
name matches fail instead of selecting an arbitrary monitor.

## Scaling and HiDPI

Percentages are relative to the native panel dimensions. For example, 250%
on a 2560×1600 panel selects a desktop near 1024×640. Selection preserves
aspect ratio and the current refresh rate when possible.

`scale` requires HiDPI and never silently substitutes a standard
low-resolution mode. `resolution` also uses HiDPI unless you explicitly pass
`--standard`. Modes must be exposed by macOS before they can be selected.

200% is an exact 2× pixel mapping for the generated HiDPI modes. Above 200%,
the rendered image is enlarged to the panel and may look softer.

If macOS does not expose the size you want, inspect and install custom requests:

```sh
monitorctl hidpi plan --display DISPLAY_UUID --scales 200,225,250,275,300 --json
monitorctl hidpi install --display DISPLAY_UUID --scales 200,225,250,275,300
# Reconnect this monitor, then check which modes macOS exposes.
monitorctl modes --display DISPLAY_UUID --hidpi
```

Only the explicit `hidpi install`/`remove` operations need administrator
authentication. Overrides preserve existing keys, other modes, and the exact
original undo backup. Entries already installed do not prompt again. Changes
made by another application are detected before an owned override is updated
or removed.

Overrides are stored by vendor/product and therefore apply to identical
panels; ordinary mode changes target a single display UUID. A reconnect or
a convenient restart is usually needed to load new requests. macOS may filter
unsupported requests, so installation does not guarantee mode availability.

```sh
monitorctl hidpi remove --display DISPLAY_UUID
```

The ownership/backup format is compatible with the earlier Larger Text
utility's `.larger-text-state.json` and `.larger-text-backup` files.

## Preview and undo

```sh
monitorctl preview 200 --seconds 20 --json
# The response includes a preview token.
monitorctl confirm PREVIEW_TOKEN
# Or restore immediately:
monitorctl revert PREVIEW_TOKEN
```

A preview returns immediately and arms an independent watchdog. Unless
confirmed, the watchdog restores the previous mode at the deadline. This
works in noninteractive agent sessions too. While a preview is pending,
other mode/override mutations are blocked; status, confirm, and revert remain
available.

Direct changes apply without a confirmation prompt. Use `--dry-run` to resolve
a change without applying it, or `--preview SECONDS` on a mode-changing command
to arm the watchdog.

```sh
monitorctl scale 250 --dry-run --json
monitorctl scale 250 --preview 20
monitorctl status --json
monitorctl undo
```

Changes normally last the current login session. Add `--permanent` to ask
macOS to save the mode across logins. Each applied change gets an independent
process read-back; concurrent CLI mutations are serialized with a file lock.

## Profiles

```sh
monitorctl save desk
monitorctl profiles
monitorctl restore desk --dry-run --json
monitorctl restore desk
```

Profiles save resolution/rendering scale and refresh rate for each active
display. All saved displays and modes must be available before a restore
transaction begins. They do not save display position or rotation.

## Agents and diagnostics

```sh
monitorctl doctor --json
monitorctl --help
```

`--json` emits `schema_version: 1`, `ok`, and structured results or errors.
Success exits 0, argument errors exit 2, and failed operations exit 1.

The installed skill teaches agents the command syntax, UUID selection,
HiDPI handling, and preview recovery. The CLI works independently of Codex.
It controls this Mac's local display session; remote agents need execution
access to that Mac.

## Scope

The implementation uses public Core Graphics and ColorSync APIs. Native panel
size comes from native-mode flags, with a labeled catalog fallback when those
flags are absent. Mirrored display mutations are rejected.

Hardware DDC/CI controls such as brightness, contrast, input selection, and
volume are outside this release, as are arrangement and rotation.

## Tests

```sh
ruby tests/core_test.rb
```

The suite covers scaling geometry, HiDPI selection, refresh matching, ambiguous
selectors, state locking, and override preservation/undo. Live preview timeout,
confirmation, revert, undo, profiles, and mode read-back were also exercised
on an LG 16MR70. Other physical displays and reboot persistence have not been
manually verified.

## References

- [Core Graphics configuration scope](https://developer.apple.com/documentation/coregraphics/cgconfigureoption)
- [Display modes](https://developer.apple.com/documentation/coregraphics/cgdisplaymode)
- [Codex skills](https://learn.chatgpt.com/docs/build-skills?product=codex)
- [Global Codex instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
