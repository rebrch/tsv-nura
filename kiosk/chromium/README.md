# Chromium kiosk mode

This mode shows your own Home Assistant dashboard full screen in Chromium, inside the cage compositor on tty1.
Use it if you'd rather design the panel in HA than run the native Rust panel.

> **Status:** these scripts have **not yet been run on the reference TSV**, which uses the native panel.
> The display stack (cage, Mesa freedreno, Wayland) is the same one the native panel uses daily.
> Chromium's memory use and GPU behaviour on the 2 GB Adreno 506 are unmeasured.
> If pages stutter, try `CHROMIUM_EXTRA_FLAGS=--disable-gpu-compositing` or a lighter dashboard.

## Install

```bash
# .env: KIOSK_MODE=chromium, HA_URL=..., HA_DASHBOARD_PATH=/lovelace/0
kiosk/setup.sh chromium
```

`kiosk/setup.sh chromium` installs:
- `chromium` and cage.
- `/usr/local/bin/tsv-chromium` (the launcher with all its flags).
- `/etc/tsv-kiosk/kiosk.env` (URL and path).
- `tsv-kiosk.service`.

The Chromium profile, which holds your HA login, is in `/var/lib/kiosk/chromium`. The HTTP cache is in RAM.

## Logging in to Home Assistant once

The TSV has no keyboard, and HA asks for a login the first time. Pick one of these options.

### A. Remote login over DevTools (no HA changes)

```bash
kiosk/chromium/login-remote.sh
```

1. The script restarts Chromium with a DevTools port bound to the TSV's localhost and tunnels it over SSH.
2. On your computer, open `chrome://inspect`, add `localhost:9222`, click **inspect** and log in. Tick "Keep me logged in".
3. Press Enter in the script. It restarts Chromium without the debug port.

The login persists in the profile.

### B. HA `trusted_networks`: the TSV logs in automatically as a dedicated user

1. In HA, create a non-admin user, e.g. `wallpanel`, and note its user ID (Settings → People → Users, open the user).
2. Add this to `configuration.yaml`:
   ```yaml
   homeassistant:
     auth_providers:
       - type: trusted_networks
         trusted_networks:
           - 192.168.1.50/32          # the TSV's (reserved) IP
         trusted_users:
           192.168.1.50: 0123456789abcdef0123456789abcdef   # wallpanel's user id
         allow_bypass_login: true
       - type: homeassistant            # keep normal logins for everyone else
   ```
3. Restart HA.

If HA sits behind a reverse proxy, HA sees the proxy's IP, not the TSV's. Either point `HA_URL` at HA directly, or configure `http: use_x_forwarded_for/trusted_proxies` properly.

### C. A USB keyboard

If you have a way to attach one, type the login on the touchscreen page directly.

## Change the URL or dashboard later

- **On the TSV:** edit `/etc/tsv-kiosk/kiosk.env`, then `sudo systemctl restart tsv-kiosk`.
- **From your computer:** update `.env` and re-run `kiosk/setup.sh chromium`.

## Switch to the native panel

Run `kiosk/setup.sh native`. It replaces the same service. The Chromium package stays installed; remove it with `apk del chromium`.
