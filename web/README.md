# Monitor Deck

Monitor Deck is a browser dashboard for monitorctl on the local Mac.
Open [Monitor Deck](http://127.0.0.1:41847) after installing the service.

## Install

Install monitorctl first, then run the dashboard installer in your macOS login
session. The installer uses Python 3 and the Swift compiler from Xcode or the
Command Line Tools.

```sh
python3 web/install.py
```

The installer copies the dashboard and its native helper into
`~/Library/Application Support/monitorctl/dashboard` and loads
`~/Library/LaunchAgents/local.monitorctl.dashboard.plist`. The LaunchAgent starts
at login and restarts the local HTTP service if it exits. The dashboard listens
on `127.0.0.1:41847`. Requests that change settings need a same-origin token.

## Use

- Select a display on the map or in the display list. Choose a resolution and
  refresh rate from the modes macOS exposes.
- Preview a mode for 20 seconds. Keep the change or let monitorctl restore the
  previous mode automatically. Remember after login saves the chosen mode.
- Drag a secondary display beside another display. You can also select a
  neighboring display and use the arrow buttons. Apply layout saves the
  arrangement, including the primary display selected with Make main.
- Undo restores the arrangement before the last dashboard layout change.
  If the display geometry has since changed, refresh and arrange it again.
- Use the existing monitorctl CLI to install additional HiDPI override requests.

The arrangement map uses the connected screens' Quartz desktop coordinates.
Mirrored displays need to be unmirrored before arranging. Each display must
touch another display along an edge so the pointer can move between them.

## Service controls

```sh
launchctl print "gui/$(id -u)/local.monitorctl.dashboard"
launchctl kickstart -k "gui/$(id -u)/local.monitorctl.dashboard"
```

Logs are in `~/Library/Application Support/monitorctl/dashboard.log`.
