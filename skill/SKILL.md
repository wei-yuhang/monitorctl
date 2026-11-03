---
name: monitor-control
description: Control this Mac's monitors with monitorctl. Use for monitor text scaling, HiDPI, resolution, refresh rate, previews, and saved display profiles.
---

Use the installed local CLI instead of writing monitor-specific display scripts.

Command: `/usr/local/bin/monitorctl`. If PATH lookup fails, use that absolute path.
The self-contained source/runtime is at `~/Library/Application Support/monitorctl/app`.

Start with `monitorctl list --json`, then `monitorctl modes --display UUID --hidpi --json`.
Use UUIDs for saved/repeated operations: numeric display IDs can change on reconnect.
`--display main` is the default; names are accepted only when unambiguous.

Examples:

```sh
monitorctl scale 250 --display UUID --json
monitorctl resolution 1024x640 --display UUID --json
monitorctl refresh 60 --display UUID --json
monitorctl preview 250 --display UUID --seconds 20 --json
monitorctl confirm TOKEN --json
monitorctl revert TOKEN --json
monitorctl undo --json
monitorctl save desk --json
monitorctl restore desk --json
```

Changes normally last the login session. Add `--permanent` when the user wants
macOS to remember a mode across logins. `--dry-run` resolves a requested change
without applying it. A preview returns immediately and an independent watchdog
restores the previous mode unless confirmed. Preview tokens are preferences,
not an extra permission requirement: use an already-authorized direct change
when appropriate. Check `monitorctl status --json` before recovering a preview.

Scale commands require HiDPI and never silently substitute a standard mode.
Resolution uses HiDPI by default; `--standard` is an explicit opt-in.
Percentages are relative to the panel's native dimensions, not the current size.
200% is exact 2× pixel mapping; above 200% the image may become softer.

When a requested size is unavailable, inspect the structured error and run:

```sh
monitorctl hidpi plan --display UUID --scales 200,225,250,275,300 --json
monitorctl hidpi install --display UUID --scales 200,225,250,275,300 --json
```

The explicit install command may show macOS's administrator authentication
dialog. It preserves existing override keys and original undo ownership, including
the older Larger Text overrides. A cable reconnect or a convenient restart is
usually needed before new sizes appear. Do not report a requested mode as active
until the CLI's read-back verifies it. `monitorctl hidpi remove` undoes only an
unchanged owned override. The tool serializes concurrent agent mutations.

Run `monitorctl doctor --json` or `monitorctl --help` for diagnostics and syntax.
This controls active displays in the local logged-in Mac session. Hardware
brightness, input selection, volume, and DDC/CI are outside this CLI's scope.
