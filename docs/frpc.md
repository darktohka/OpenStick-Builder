# frpc

The image bundles an `arm64` build of [frp](https://github.com/fatedier/frp)
— specifically the client, **frpc**. frp lets the OpenStick reach out to a
public `frps` server and expose local services (SSH, the sms-gateway WebUI,
...) through it, so you can reach the stick from the Internet even though it
sits behind the carrier's NAT on `wwan0`.

Only `frpc` is installed; `frps` runs on a server you control.

## Why a reverse tunnel

The OpenStick gets its uplink from the cellular modem (`wwan0`,
`10.x.x.x/30` via DHCP), so it has no public address and inbound connections
aren't possible. With frpc, the stick dials *out* to your `frps` server and
keeps a persistent connection; the server then forwards matching traffic back
down the tunnel to a local port on the stick (e.g. SSH `22` or the
sms-gateway WebUI on `5174`).

## Layout on the device

| Path | Purpose |
| ---- | ------- |
| `/usr/local/bin/frpc` | static arm64 binary (built with the `noweb` tag — no embedded admin web UI; see below) |
| `/etc/frp/frpc.toml` | config template (placeholder server, disabled) |
| `/etc/systemd/system/frpc.service` | unit (shipped but **not** enabled) |

## Enable it

`frpc.service` is deliberately **disabled by default**: you must point frpc at
your own `frps` server first.

1. Edit `/etc/frp/frpc.toml` on the device and set your real `serverAddr`,
   `serverPort` and `auth.token`, and the `[[proxies]]` you want
   (see `conf/frpc_full_example.toml` in the frp source for every option).
2. Start it:

   ```sh
   sudo systemctl enable --now frpc
   systemctl status frpc
   ```

The config ships with two example proxies (SSH on remote port `6022`, and a
commented-out sms-gateway on `65174`) to show the shape; delete or extend them
as needed.

## Build

[`scripts/build_frpc.sh`](../scripts/build_frpc.sh) cross-compiles `./cmd/frpc`
from the pinned `src/frp` submodule (tag `v0.71.0`) for `linux/arm64` with
CGO disabled and stages the static binary at
`dist/usr/local/bin/frpc`, which `scripts/build_images.sh` copies into the
final rootfs image (same mechanism as `scripts/build_gt.sh`).

Only **Go `>= 1.25`** is needed — frp requires no frontend build.

The binary is compiled with the `noweb` build tag (the same thing upstream
`make frpc` does when the `web/` dashboard hasn't been built). This drops the
embedded admin *web UI* so the binary stays ~14 MB and CI doesn't need
Node.js. frpc's functionality is unaffected — proxies, the tunnel and the
admin REST API all work; only the optional browser dashboard is missing.

To update the pinned version:

```sh
git submodule update --remote src/frp   # only meaningful if branch is set
# or: cd src/frp && git fetch --tags && git checkout <tag>
git add src/frp && git commit
```

## Notes

- frpc is `After=network-online.target` and `Restart=on-failure` with a 5 s
  backoff, so it keeps retrying until `wwan0` is up (and reconnects if the
  tunnel drops).
- The tunnel exits through the same `wwan0` link the hotspot and sms-gateway
  use; traffic overhead is negligible.
- If you don't need remote access, simply never enable `frpc.service` — the
  installed binary and config are inert.
