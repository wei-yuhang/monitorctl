it's basic human right to scale your monitor and macOS doesn't give you that.

# monitorctl

You bought the screen. You should get to decide how big things look on it.
Use monitorctl to pick a size you can read, set the refresh rate, and save
a setup worth coming back to.

Prefer dragging screens around? [Monitor Deck](web/README.md) puts the controls
in your browser. Drag each display to match where it sits on your desk. The
dashboard starts at login.

```sh
monitorctl list
monitorctl modes --hidpi
monitorctl scale 250
monitorctl undo
```

## Install the CLI

```sh
git clone https://github.com/EricWay1024/monitorctl.git
cd monitorctl
python3 install.py
```

You'll need macOS, its bundled Ruby, and Python 3 for the installer. Run
display commands from a logged-in desktop session. The installer puts
`monitorctl` in `/usr/local/bin` and keeps the app in
`~/Library/Application Support/monitorctl/app`. It also installs the
[monitor-control skill](skill/SKILL.md) and adds a discovery note to your Codex
instructions.

macOS may ask for your administrator password when the installer creates the
global command. Ordinary display changes run as your user.

Just looking? Run these from the checkout.

```sh
ruby monitorctl --help
ruby monitorctl list --json
```

## Put the controls in your browser

Install the CLI first, then run this from the same checkout. The installer
builds the arrangement helper with Swift from Xcode or the Command Line Tools.

```sh
python3 web/install.py
```

Open [Monitor Deck](http://127.0.0.1:41847). Pick a display, preview a mode,
or drag the monitors into place and click **Apply layout**.

## Pick the right screen

Commands default to the main display. Use a UUID, the current numeric ID,
or part of the name to pick another screen. `external` works when you have
exactly one external display.

```sh
monitorctl list --json
monitorctl modes --display external --hidpi
monitorctl scale 250 --display DISPLAY_UUID --json
monitorctl resolution 1024x640 --display DISPLAY_UUID
monitorctl refresh 60 --display DISPLAY_UUID
```

Use UUIDs in scripts. Numeric IDs can change when you reconnect a cable,
and monitorctl rejects names that match more than one screen.

## Make the text big enough

Scale is relative to your panel's native dimensions. On a 2560×1600 panel,
250% gives you a desktop near 1024×640. monitorctl keeps the aspect ratio and
tries to keep your current refresh rate.

`scale` uses HiDPI, with `scale 100` for the native desktop. To pick a
standard resolution directly, use `resolution --standard`. On the HiDPI
modes generated here, 200% gives you exact 2× pixel mapping. Bigger text above
200% can look softer because macOS stretches the rendered image to fit the
panel.

If the size you want is missing, add it to the list macOS considers.

```sh
monitorctl hidpi plan --display DISPLAY_UUID --scales 200,225,250,275,300 --json
monitorctl hidpi install --display DISPLAY_UUID --scales 200,225,250,275,300
# Reconnect the screen, then see what macOS accepted.
monitorctl modes --display DISPLAY_UUID --hidpi
```

Installing or removing an override requires administrator authentication.
monitorctl keeps the other modes and keys and saves the original file for
undo. If another app edits an override afterward, monitorctl stops before
overwriting it. It also recognizes backups from the earlier Larger Text tool.

An override applies to panels with the same vendor and product ID. Regular
mode changes target one display UUID. You may need to reconnect the display
or restart, and macOS can still reject a requested mode.

```sh
monitorctl hidpi remove --display DISPLAY_UUID
```

## Try it before you keep it

Give a new mode 20 seconds. If the screen looks wrong, let the timer run out.
The old mode comes back even if the shell that started the preview closes.

```sh
monitorctl preview 200 --seconds 20 --json
monitorctl confirm PREVIEW_TOKEN
# To go back early:
monitorctl revert PREVIEW_TOKEN
```

Use the token from the preview response. While the timer runs, finish or
revert that preview before starting another display change.

```sh
monitorctl scale 250 --dry-run --json
monitorctl scale 250 --preview 20
monitorctl status --json
monitorctl undo
```

Add `--permanent` if you want the mode to survive logout. The CLI reads the
mode back after applying it and runs one change at a time.

## Save a setup you like

```sh
monitorctl save desk
monitorctl profiles
monitorctl restore desk --dry-run --json
monitorctl restore desk
```

A profile saves each active display's resolution, rendering scale, and refresh
rate. Connect all the displays in the profile before restoring it. Use Monitor
Deck to move screens around.

## Let an agent drive

```sh
monitorctl doctor --json
monitorctl --help
```

The bundled skill covers display selection, HiDPI, and preview recovery.
`--json` gives you `schema_version: 1`, `ok`, and structured results or
errors. Exit codes are 0 for success, 2 for argument errors, and 1 for failed
operations. A remote agent needs execution access to the Mac whose displays
it will change.

## What you can control

The CLI uses Core Graphics and ColorSync to set display modes. If macOS
doesn't flag a native size, monitorctl labels the estimate it makes from
the mode list. Turn off mirroring before rearranging displays.

Monitor Deck handles arrangement. Brightness, input switching, volume,
contrast, and rotation are outside its current controls.

## Check the code

```sh
ruby tests/core_test.rb
```

The tests cover scaling, HiDPI selection, refresh matching, duplicate display
names, state locking, and override undo. Preview, confirm, revert, profiles,
and mode read-back were also tested on an LG 16MR70.

## References

- [Core Graphics configuration scope](https://developer.apple.com/documentation/coregraphics/cgconfigureoption)
- [Display modes](https://developer.apple.com/documentation/coregraphics/cgdisplaymode)
- [Codex skills](https://learn.chatgpt.com/docs/build-skills?product=codex)
- [Global Codex instructions](https://learn.chatgpt.com/docs/agent-configuration/agents-md)

## License

monitorctl and Monitor Deck are yours to use and change under the
[MIT license](LICENSE).
