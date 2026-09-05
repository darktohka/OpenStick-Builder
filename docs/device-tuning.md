# Device tuning services

The Debian image ships two extra oneshot units that run at boot to adapt the
generic postmarketOS MSM8916 kernel to the modem-stick form factor. They live
in the image under `/etc/systemd/system` and are enabled for
`multi-user.target` via symlinks in
`configs/system/multi-user.target.wants/`.

## cleanup-wwan.service

`After=ModemManager.service` / `Wants=ModemManager.service`, runs the helper
script `/usr/local/sbin/cleanup-wwan`.

The modem on these sticks exposes one network interface per SIM slot
(`wwan0`..`wwan7`), but only `wwan0` is the real, connected uplink. The helper:

1. Creates a `null` network namespace (`ip netns add null`).
2. Waits up to 20 s for the modem links to appear (polling `wwan7`).
3. Moves every other link (`wwan1`..`wwan7`) into the `null` netns so
   NetworkManager never sees or tries to manage them.
4. If `wwan0` still has no IPv4 address afterwards, restarts
   `ModemManager.service` (some boards need this delay to initialize).

The result: exactly one modem interface (`wwan0`) is visible to NetworkManager
and it connects over LTE (as `wwan0qmi0`), which is the uplink the WiFi
hotspot NATs through.

## disable-cpu-cores.service

Powers off CPU cores 2 and 3 of the quad-core MSM8916 to save power:

```ini
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo 0 > /sys/devices/system/cpu/cpu2/online; echo 0 > /sys/devices/system/cpu/cpu3/online'
RemainAfterExit=yes
```

To bring all cores back (e.g. for benchmarking):

```sh
sudo systemctl disable --now disable-cpu-cores.service
echo 1 | sudo tee /sys/devices/system/cpu/cpu2/online /sys/devices/system/cpu/cpu3/online
```
