#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Prepare wlan0 to act as a software access point and enable NAT for the
# hotspot subnet out through the WWAN (LTE) uplink.
#
# This runs as ExecStartPre of openstick-hotspot.service, i.e. before
# hostapd starts. hostapd only needs the interface to exist in AP mode and
# carry the subnet address; it brings the link up itself once beaconing.

set -e

WLAN=wlan0

# Stop NetworkManager from touching wlan0 (prevents wcn36xx scan race)
nmcli device set "$WLAN" managed no 2>/dev/null || true

# Put wlan0 in AP mode
ip link set "$WLAN" down || true
iw dev "$WLAN" set type ap 2>/dev/null || true
ip link set "$WLAN" up || true

# Static IP for AP subnet
ip addr flush dev "$WLAN" 2>/dev/null || true
ip addr add 192.168.4.1/24 dev "$WLAN" 2>/dev/null || true

# Enable NAT so hotspot clients reach the internet via wwan0
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
iptables -t nat -C POSTROUTING -s 192.168.4.0/24 -o wwan0 -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s 192.168.4.0/24 -o wwan0 -j MASQUERADE
iptables -C FORWARD -i "$WLAN" -o wwan0 -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i "$WLAN" -o wwan0 -j ACCEPT
iptables -C FORWARD -i wwan0 -o "$WLAN" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -i wwan0 -o "$WLAN" -m state --state RELATED,ESTABLISHED -j ACCEPT

exit 0
