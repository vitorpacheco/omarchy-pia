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
- Automatic region shows the connected location, e.g. "Automatic · Brazil".
- VPN IP and public IP rows that copy to the clipboard. They open blurred and
  a toggle row (or the `v` key) reveals them for the current session only.
- WireGuard / OpenVPN switch, port forwarding request (shows the forwarded
  port), and LAN access toggle.
- Log in from a terminal prompt (credentials only ever touch a private temp
  file that is shredded afterwards) and log out.
- Live updates via `piactl monitor`, plus a polling fallback.
- Optional desktop notifications when the VPN connects, drops or is
  interrupted.
- English, Spanish and Portuguese interface, notifications and terminal login,
  selected from the system language with English as the fallback.

## Requirements

- Omarchy 4.x (shell plugins with `manifest.json`).
- The PIA desktop client, which ships `piactl` and the `piavpn` daemon:

  ```bash
  yay -S piavpn-bin
  sudo systemctl enable --now piavpn
  ```

- `wl-copy` for the copy actions and `gum` for the login prompt (both come
  with Omarchy).
- Python 3 for secure login marker handling.
- `jq` to show the actual location when using Automatic region.
- `notify-send` (`libnotify`) for desktop notifications, plus Bash, GNU
  coreutils and grep for the CLI helpers (included with Omarchy).

A PIA subscription and an authenticated PIA session are required to connect.
Use the widget's **Log in** action to authenticate in a terminal.

### Permissions and data

The plugin runs inside the Omarchy shell as your user. It does not install
packages, download executables, or invoke `sudo` at runtime. Installing PIA
and enabling its system service are explicit setup steps above; the separately
installed PIA daemon manages the privileged VPN operations.

The widget invokes `piactl` to read and change VPN settings, reads the login
flag from PIA's daemon log, and uses the terminal, clipboard and notification
tools listed above. Login credentials are passed to `piactl` in a temporary
file with mode `600`, which is removed on exit. The account name and recent
regions are saved in the widget's own entry in `shell.json`; a login marker
containing the account name is written with mode `600` under `XDG_RUNTIME_DIR`.
Login from the widget requires this directory to be owned by the current user
with mode `700`, with no symlink components; there is no `/tmp` fallback.
Marker creation is exclusive, and reads and removal reject symlinks, foreign
owners, unsafe permissions, and multiple hard links.

## Install

```bash
omarchy plugin add https://github.com/vitorpacheco/omarchy-pia.git --enable
```

Move it around the bar with `omarchy bar move io.github.vitorpacheco.pia --section right`
and update it later with `omarchy plugin update io.github.vitorpacheco.pia`.

## Remove

```bash
omarchy plugin remove io.github.vitorpacheco.pia
```

Removing the widget does not uninstall PIA or stop its daemon. If you also
want to end an active VPN connection, run `piactl disconnect` first. To restore
a hidden PIA launcher entry, remove the user override described below.

## Use without the graphical app

The `piavpn-bin` package bundles the graphical app, `piactl` and the daemon.
Removing it with `pacman -R` removes all three. Keep the package installed
and hide the graphical app instead:

1. Make sure the daemon is enabled and background mode is on:

   ```bash
   sudo systemctl enable --now piavpn
   piactl background enable
   ```

   The daemon runs independently of the graphical app. The widget also runs
   `piactl background enable` before each connection when `backgroundMode`
   is `true` (the default).

2. Quit the PIA graphical app using its tray menu. This also stops its
   notifications, leaving the widget to report connection changes. If you
   previously enabled the app to launch at login, disable that option too.

3. Hide its launcher entry for your user:

   ```bash
   mkdir -p ~/.local/share/applications
   cp /usr/share/applications/piavpn.desktop ~/.local/share/applications/
   echo "NoDisplay=true" >> ~/.local/share/applications/piavpn.desktop
   ```

   This user override survives package updates. It hides the launcher entry;
   it does not stop a running app or disable autostart.

To show the launcher entry again, remove the override created above:

```bash
rm ~/.local/share/applications/piavpn.desktop
```

Avoid manually deleting `/opt/piavpn/bin/pia-client`: `pacman -Qk piavpn-bin`
would report a missing package file, and an update would restore it.

## Language

The plugin follows the shell process's language: `LC_ALL`, then `LC_MESSAGES`,
then `LANG` (or Qt's locale if none is set). It supports English (`en`),
Spanish (`es`) and Portuguese (`pt`), including regional variants such as
`en_US`, `es_MX`, `pt_BR` and `pt_PT`. Unsupported locales, including `C` and
`POSIX`, and missing translations fall back to English.

Menus, connection states, notifications, country names and the terminal login
are localized. Region search accepts translated names, English names and PIA
region IDs, with or without accents. Keyboard shortcuts and IPC responses
stay the same in every language.

The language is read from the running shell's environment. After changing your
session language, log out and back in so the shell inherits the new locale.
Raw messages from `piactl`, server names without a translation, and the
manifest's metadata/settings labels remain in English or their original form.

## Keyboard shortcuts

Inside the panel:

- `j` / `k` or arrows: move the cursor
- `enter` / `space`: activate the row (or flip the switch in the header)
- `t`: toggle the VPN
- `g` or `/`: open the region picker; type to filter, `esc` closes it
- `v`: show or blur the IP addresses
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
omarchy-shell pia account    # account name once known, else "unknown"
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

`recentRegions` and `accountName` are written by the widget itself.

## Automatic region detection

The automatic region label reads `connectedConfig.vpnLocation.id` from
`piactl -u dump daemon-state`, since `piactl get region` only returns `auto`.
This is an [unstable PIA API](https://github.com/pia-foss/desktop/issues/17):
if it is unavailable or its format changes, the widget falls back to
"Automatic" and keeps the usual connection controls working. The resolved
location is shown only while connected; Automatic remains selected.

## Account detection

`piactl` has no command to report the logged-in account, and the PIA daemon
socket rejects clients other than its own binaries, so the widget never probes
with credentials. It reads the login flag PIA itself writes to its
world-readable daemon log (`/opt/piavpn/var/daemon.log`, present while PIA
debug logging is on, which is the default) and treats an active connection as
logged in. The account name is learned only when you log in through the
widget's own terminal prompt and cached in `accountName`; if you were already
logged in before installing the widget, log out and back in through it once to
record the name.

Connect/disconnect notifications wait until the tunnel details (VPN and public
IP) match the reported state, so they fire when the transition has finished
rather than the moment piactl flips its state. The PIA desktop app, when it is
open, posts its own "Connecting to…" / "Connected to…" toasts at every state
change; turn off "Show desktop notifications" in the app's settings if you
only want the widget's.

## Development

Copy the checkout into `~/.config/omarchy/plugins/io.github.vitorpacheco.pia/`
(or install it with `omarchy plugin add file:///path/to/checkout`). Saved files
hot-reload; after larger changes `omarchy restart shell` gives a clean instance.
Validate the manifest with `omarchy plugin validate .` and read the shell log
with `qs log -p /usr/share/omarchy/shell -t 100`.

`Model.js` holds every pure helper (state parsing, region labels, filtering)
and `Service.qml` owns all `piactl` processes; `Panel.qml` is only the view.
`I18n.js` contains the English, Spanish and Portuguese catalogs and locale
helpers. English source messages are translation keys; keep named placeholders
such as `{name}` intact in translations. The standalone login script carries
its own small Bash catalog so it does not need a JavaScript runtime.

Run the regression tests with `node --test tests/*.cjs` (Node.js and `jq`
required for tests). They cover automatic regions, locale fallback, translated
panel rows and notifications, region search, and the terminal login with a
mock PIA client.
