# Private Internet Access for Omarchy

Native [Omarchy](https://omarchy.org) bar widget for the
[Private Internet Access](https://www.privateinternetaccess.com/) VPN. It talks
to the PIA daemon through `piactl`, so the desktop client does not need to be
open.

## Features

- Shield icon in the bar: solid when connected, struck through when off,
  pulsing while a connection is in flight, badged when you need to log in.
- Left click opens a keyboard-friendly panel, right click toggles the VPN,
  middle click refreshes.
- Connect / disconnect from a switch in the panel header.
- Region picker with search, flags, "Automatic", dedicated IPs and a pinned
  list of the regions you used recently. Picking a region while disconnected
  connects there.
- VPN IP and public IP rows that copy to the clipboard.
- WireGuard / OpenVPN switch, port forwarding request (shows the forwarded
  port), and LAN access toggle.
- Log in from a terminal prompt (credentials only ever touch a private temp
  file that is shredded afterwards), log out, open the PIA app.
- Live updates via `piactl monitor`, plus a polling fallback.
- Optional desktop notifications when the VPN connects, drops or is
  interrupted.

## Requirements

- Omarchy 4.x (shell plugins with `manifest.json`).
- The PIA desktop client, which ships `piactl` and the `piavpn` daemon:

  ```bash
  yay -S piavpn-bin
  sudo systemctl enable --now piavpn
  ```

- `wl-copy` for the copy actions and `gum` for the login prompt (both come
  with Omarchy).

## Install

```bash
omarchy plugin add https://github.com/vitorpacheco/omarchy-pia.git --enable
```

Move it around the bar with `omarchy bar move io.github.vitorpacheco.pia --section right`
and update it later with `omarchy plugin update io.github.vitorpacheco.pia`.

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: move the cursor
- `enter` / `space`: activate the row (or flip the switch in the header)
- `t`: toggle the VPN
- `g` or `/`: open the region picker; type to filter, `esc` closes it
- `c`: copy the VPN IP
- `p`: copy the public IP
- `r`: refresh
- `esc`: close

## IPC

Everything is scriptable through the shell IPC target `pia`, handy for
Hyprland keybindings:

```bash
omarchy-shell pia toggleVpn
omarchy-shell pia connect
omarchy-shell pia disconnect
omarchy-shell pia setRegion uk-london
omarchy-shell pia status     # prints e.g. "Connected"
omarchy-shell pia region     # prints the region id
omarchy-shell pia toggle     # open/close the panel
```

## Settings

Edit the widget entry in `~/.config/omarchy/shell.json` (or use the bar
settings UI):

| Key                  | Default | Meaning                                                      |
|----------------------|---------|--------------------------------------------------------------|
| `refreshIntervalSec` | `30`    | Fallback polling interval in seconds.                        |
| `ctlPath`            | `""`    | Explicit path to `piactl` (empty = PATH or /opt/piavpn/bin). |
| `backgroundMode`     | `true`  | Run `piactl background enable` before connecting.            |
| `notifications`      | `true`  | Desktop notification on connect / disconnect / interrupted.  |
| `maxRecentRegions`   | `5`     | How many recent regions to pin in the panel.                 |

`recentRegions` is written by the widget itself.

## Development

Copy the checkout into `~/.config/omarchy/plugins/io.github.vitorpacheco.pia/`
(or install it with `omarchy plugin add file:///path/to/checkout`). Saved files
hot-reload; after larger changes `omarchy restart shell` gives a clean instance.
Validate the manifest with `omarchy plugin validate .` and read the shell log
with `qs log -p /usr/share/omarchy/shell -t 100`.

`Model.js` holds every pure helper (state parsing, region labels, filtering)
and `Service.qml` owns all `piactl` processes; `Panel.qml` is only the view.
