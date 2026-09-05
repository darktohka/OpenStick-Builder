# SMS gateway

The image bundles an `arm64` build of
[sms-gateway](https://github.com/mattboston/sms-gateway), a Go application
with an embedded React WebUI and a REST API for sending and receiving SMS via
AT commands on a GSM modem.

On the OpenStick there is no USB serial modem — the modem is the Qualcomm
MDM4094 SoC inside the stick, exposed by the kernel as three `rpmsg` ports:

| Port | Used by |
| ---- | ------- |
| `/dev/wwan0at0` | ModemManager (AT) — manages the cellular data connection |
| `/dev/wwan0at1` | **sms-gateway** (AT) — reserved by a udev rule |
| `/dev/wwan0qmi0` | ModemManager (QMI) |

## How the two coexist

ModemManager would normally grab every `wwan*` port it can probe
(`ID_MM_CANDIDATE=1`). To let sms-gateway own the second AT port, the rule at
[`configs/udev/rules.d/99-sms-gateway.rules`](../configs/udev/rules.d/99-sms-gateway.rules)
installed as `/etc/udev/rules.d/99-sms-gateway.rules` marks `/dev/wwan0at1`
as a non-candidate and asks ModemManager to ignore it:

```
SUBSYSTEM=="wwan", KERNEL=="wwan0at1", ENV{ID_MM_CANDIDATE}="0", ENV{ID_MM_PORT_IGNORE}="1"
```

ModemManager keeps `/dev/wwan0at0` and `/dev/wwan0qmi0`, so the `wwan0`
cellular data link is unaffected — the WiFi hotspot, USB networking and LTE
uplink all keep working while sms-gateway serves SMS on `wwan0at1`.

## Build

`sms-gateway` embeds a React frontend (`src/web`) via `go:embed`, so building
it requires both a frontend build and a Go cross-compile:

- **Node.js** `>= 20.19` (Vite 8 requirement) — for `npm ci && npm run build`
- **Go** `>= 1.25` (per `src/go.mod`)

[`scripts/build_sms_gateway.sh`](../scripts/build_sms_gateway.sh) does both and
stages the static binary at `dist/usr/local/bin/sms-gateway`, which
`scripts/build_images.sh` copies into the final rootfs image (same mechanism
as `scripts/build_gt.sh`).

The source is pinned as the `src/sms-gateway` git submodule. To update it:

```sh
git submodule update --remote src/sms-gateway   # pulls the latest origin/main
git add src/sms-gateway && git commit
```

## Layout on the device

| Path | Purpose |
| ---- | ------- |
| `/usr/local/bin/sms-gateway` | static arm64 binary |
| `/opt/sms-gateway/sms-gateway.conf` | config (device `/dev/wwan0at1`, port `5174`) |
| `/opt/sms-gateway/sms-gateway.db` | SQLite database (created on first run) |
| `/etc/systemd/system/sms-gateway.service` | unit, enabled for `multi-user.target` |
| `/etc/udev/rules.d/99-sms-gateway.rules` | reserves `/dev/wwan0at1` |

First boot seeds an `admin` user with password `admin123`; the WebUI forces a
password change on first login.

## Control

```sh
systemctl status sms-gateway
sudo journalctl -u sms-gateway -f
sudo systemctl restart sms-gateway
sudo systemctl disable --now sms-gateway   # stop + stop running at boot
```

## Why the service differs from upstream

The upstream
[`deploy/systemd/sms-gateway.service`](https://github.com/mattboston/sms-gateway/blob/main/deploy/systemd/sms-gateway.service)
targets USB modems (`/dev/ttyUSB2`), runs as an unprivileged `sms-gateway`
user and hardens the unit with `ProtectSystem`/`ProtectHome`. The image's
unit ([`configs/system/sms-gateway.service`](../configs/system/sms-gateway.service))
instead:

- runs as `root` so it can open the `root:root` `crw-------` `/dev/wwan0at1`
- uses `After=ModemManager.service` so ordering is deterministic
- points at the config in `/opt/sms-gateway`
