# WiFi hotspot on wlan0 (hostapd)

The OpenStick exposes a Wi-Fi access point on `wlan0` with SSID `Openstick`
(password `openstick`) at `192.168.4.1`, giving clients internet access
through the LTE uplink (`wwan0`) via NAT.

## Quick reference

| Component            | File                                                            | Purpose                                            |
| -------------------- | --------------------------------------------------------------- | -------------------------------------------------- |
| hostapd config       | `/etc/hostapd/hostapd.conf`                                     | AP parameters (SSID, password, channel, security)  |
| hostapd service      | `openstick-hotspot.service`                                     | Brings up the AP and runs hostapd                  |
| setup helper         | `/usr/local/sbin/openstick-hotspot-setup.sh`                    | Puts wlan0 in AP mode + installs NAT               |
| DHCP server          | `dnsmasq-openstick.service` + `/etc/dnsmasq-openstick.conf`     | Hands out `192.168.4.x` addresses                  |
| NM override          | `/etc/NetworkManager/NetworkManager.conf`                       | Tells NM to leave wlan0 alone                      |

```shell
systemctl status openstick-hotspot.service     # check the AP
systemctl restart openstick-hotspot.service    # apply config changes
systemctl status dnsmasq-openstick.service     # check DHCP
```

Edit `/etc/hostapd/hostapd.conf` to change the SSID, passphrase or channel,
then `systemctl restart openstick-hotspot`.

---

## Why hostapd and not NetworkManager's hotspot?

The image originally shipped a NetworkManager connection profile
(`hotspot.nmconnection`) and expected `nmcli con up hotspot` to create the
access point. On these MSM8916 dongles (e.g. UZ801, `wcn36xx` Wi-Fi) that
**fails reliably** with:

```
NetworkManager: device (wlan0): Activation: (wifi) Hotspot network creation took too long, failing activation
NetworkManager: device (wlan0): state change: config -> failed (reason 'supplicant-timeout', ...)
```

### The mechanism

NetworkManager drives Wi-Fi through `wpa_supplicant`. To run an access point
it asks the supplicant to enable AP mode on the interface. Meanwhile
NetworkManager also runs periodic Wi-Fi **scans** (for connectivity checks /
roaming state). These two operations race on the `wcn36xx` driver:

1. A scan is started (`Workqueue: phy0 ieee80211_scan_work`).
2. NM flips the interface (e.g. restores/changes the MAC address, takes the
   link down and up) at the same time the AP setup is being requested.
3. The driver aborts the scan mid-flight, but mac80211 is left in an
   inconsistent state. The kernel then logs a warning and the AP activation
   can never complete:

```
WARNING: CPU: 0 PID: 11 at net/mac80211/scan.c:423 __ieee80211_scan_completed
Workqueue: phy0 ieee80211_scan_work
```

4. `wpa_supplicant` never reports the AP as ready, NetworkManager waits its
   25 second timeout and gives up with `supplicant-timeout`.

Direct evidence gathered on hardware:

```
[    9.591282] wcn36xx: firmware API 1.5.1.2, 41 stations, 2 bssids
[  122.070227] WARNING: CPU: 0 PID: 11 at net/mac80211/scan.c:423 __ieee80211_scan_completed
[  122.134740] Workqueue: phy0 ieee80211_scan_work
```

while `hostapd` (which talks to the driver directly over `nl80211` and never
runs its own scans) brings the same radio up cleanly:

```
hostapd: wlan0: interface state UNINITIALIZED->COUNTRY_UPDATE
hostapd: wlan0: interface state COUNTRY_UPDATE->ENABLED
hostapd: wlan0: AP-ENABLED
```

So the fix is to run the access point with **hostapd** and keep NetworkManager
away from `wlan0` so it cannot trigger the scan race.

---

## How each piece fits together

### NetworkManager config (`configs/NetworkManager.conf`)

```ini
[keyfile]
unmanaged-devices=interface-name:wlan0
```

`wlan0` is removed from NetworkManager's control. NM keeps managing the
other links (`usb0`, `wwan0qmi0`/LTE) exactly as before. This is the single
most important change: it stops NM from scanning `wlan0` and from trying to
activate the old (broken) hotspot profile.

Because of this, the old `configs/hotspot.nmconnection` was **deleted** —
keeping it around would only confuse people into trying `nmcli con up hotspot`
again.

### Setup helper (`scripts/openstick-hotspot-setup.sh`)

Runs once before hostapd starts (`ExecStartPre`). It:

1. Re-asserts that NM is not managing `wlan0`.
2. Takes the interface down and switches it to **AP** type:
   `iw dev wlan0 set type ap`.
3. Assigns the AP address `192.168.4.1/24`.
4. Enables IPv4 forwarding and installs NAT so hotspot clients can reach the
   internet through the LTE uplink:
   - `MASQUERADE` packets from `192.168.4.0/24` going out `wwan0`
   - `FORWARD` rules allowing traffic between `wlan0` and `wwan0`

`hostapd` then brings the link up itself once it starts beaconing (the helper
leaves the interface `UP`; hostapd sets `LOWER_UP` when the AP is enabled).

### hostapd config (`configs/hostapd.conf`)

The AP parameters, matching the defaults documented in the README:

- SSID `Openstick`, WPA2 (`wpa=2`, `rsn_pairwise=CCMP`), passphrase
  `openstick`.
- `hw_mode=g`, `channel=6` (2.4 GHz). `wcn36xx` does not support 5 GHz AP
  operation on these boards, so keep it on 2.4 GHz.
- `country_code=US` selects a regulatory domain with channels 1-11 usable for
  an AP. (With the default world domain the regulatory update can time out;
  hostapd continues anyway, but setting a country avoids the noise.)

### hostapd service (`configs/system/openstick-hotspot.service`)

`Type=simple`, `Restart=on-failure`. Ordered after NetworkManager so NM has
finished claiming (or not claiming) devices before the helper runs.

### DHCP server (`configs/system/dnsmasq-openstick.service` + `configs/dnsmasq-openstick.conf`)

Clients need an IP address, so a small DHCP server runs on `wlan0`:

- `dhcp-range=192.168.4.10,192.168.4.250` leases addresses in the AP subnet.
- `dhcp-option` hands out the gateway (`192.168.4.1`) and the LTE network's
  DNS servers (`100.100.1.1`, `100.100.0.1` — the value `nmcli` reports for
  the `wwan0qmi0` link; adjust if your carrier differs).
- `port=0` **disables dnsmasq's DNS server**. NetworkManager already runs its
  own dnsmasq bound to `127.0.0.1:53` for the usb0/LTE connections; enabling
  DNS here would fail with `Address already in use`.
- `interface=wlan0` + `bind-interfaces` keeps this DHCP server on the
  hotspot link so it cannot conflict with NM's DHCP server for `usb0` (both
  may listen on UDP/67 but are bound to different interfaces).

The service is started as a unit rather than via NM's "shared" connection
mode because the latter would route the hotspot back through the broken
wpa_supplicant path.

### Enablement

Both units are enabled for `multi-user.target` via symlinks in
`configs/system/multi-user.target.wants/` (same pattern as
`msm-firmware-loader.service`), so the hotspot starts automatically at boot.

---

## Frequently asked questions

### Can I still use wlan0 to join a normal Wi-Fi network (client mode)?

Yes, but not at the same time as the hotspot. To use client mode:

```shell
sudo systemctl stop openstick-hotspot dnsmasq-openstick
sudo sed -i '/unmanaged-devices=interface-name:wlan0/d' /etc/NetworkManager/NetworkManager.conf
sudo systemctl restart NetworkManager
nmcli radio wifi on
nmcli dev wifi connect "YOUR_SSID" password "YOUR_PASS"
```

Note: the same scan/AP race that breaks the hotspot can also make client-mode
connections flaky on some firmware versions. If connecting as a client fails,
see "Troubleshooting".

### The AP is enabled but clients cannot reach the internet

Check the NAT rules and forwarding are in place and that LTE is the uplink:

```shell
systemctl status openstick-hotspot dnsmasq-openstick
iptables -t nat -L POSTROUTING -n     # expect the 192.168.4.0/24 MASQUERADE rule
cat /proc/sys/net/ipv4/ip_forward    # expect 1
nmcli device                             # wwan0qmi0 should be connected
```

If your carrier's DNS servers differ, update
`/etc/dnsmasq-openstick.conf` (`dhcp-option=option:dns-server,...`) and
restart `dnsmasq-openstick.service`.

### I see `wcn36xx: ERROR hal_delete_sta_self response failed err=7` in dmesg

This is a known cosmetic driver/firmware message that appears when the driver
tears down a station/interface and the firmware does not acknowledge. It does
not prevent the hostapd-based hotspot from working and can be ignored.

### Why does NetworkManager still log about wlan0?

If NM was restarted while hostapd owns `wlan0`, it may briefly show the
device; the `unmanaged-devices` rule keeps it from configuring it. If you see
the old `hotspot` connection listed in `nmcli`, delete it once:

```shell
sudo nmcli connection delete hotspot
```

This profile is no longer shipped in the image.
