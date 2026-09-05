# OpenStick Image Builder
Image builder for MSM8916 based 4G modem dongles

This builder uses the precompiled [kernel](https://pkgs.postmarketos.org/package/v24.06/postmarketos/aarch64/linux-postmarketos-qcom-msm8916) provided by [postmarketOS](https://postmarketos.org/) for Qualcomm MSM8916 devices.

> [!NOTE]
> This branch generates a `debian` image, use the [alpine branch](https://github.com/kinsamanka/OpenStick-Builder/tree/alpine) for an `alpine` image.

## Build Instructions
### Build locally
This has been tested to work on **Ubuntu 22.04**
- clone
  ```shell
  git clone --recurse-submodules https://github.com/kinsamanka/OpenStick-Builder.git
  cd OpenStick-Builder/
  ```
#### Quick
- build
  ```shell
  cd OpenStick-Builder/
  sudo ./build.sh
  ```
#### Detailed
- install dependencies
  ```shell
  sudo scripts/install_deps.sh
  ```
- build hyp and lk2nd

  these custom bootloader allows basic support for `extlinux.conf` file, similar to u-boot and depthcharge.
  ```shell
  sudo scripts/build_hyp_aboot.sh
  ```
- extract Qualcomm firmware

  extracts the bootloader and creates a new partition table that utilizes the full emmc space
  ```shell
  sudo scripts/extract_fw.sh
  ```
- create rootfs using debootstrap
  ```shell
  sudo scripts/debootstrap.sh
  ```

- build gadget-tools
  ```shell
  sudo scripts/build_gt.sh
  ```
- build sms-gateway (needs Go >= 1.25 and Node.js >= 20.19 on the host)
  ```shell
  sudo scripts/build_sms_gateway.sh
  ```
- create images
  ```shell
  sudo scripts/build_images.sh
  ```

The generated firmware files will be stored under the `files` directory

### On the cloud using Github Actions
1. Fork this repo
2. Run the [Build workflow](../../actions/workflows/build.yml)
   - click and run ***Run workflow***
   - once the workflow is done, click on the workflow summary and then download the resulting artifact

## Customizations
Edit [`scripts/setup.sh`](scripts/setup.sh) to add/remove packages. Note that this script is running inside the `chroot` environment.

## Firmware Installation
> [!WARNING]  
> The following commands can potentially brick your device, making it unbootable. Proceed with caution and at your own risk!

> [!IMPORTANT]  
> Make sure to perform a backup of the original firmware using the command `edl rf orig_fw.bin`

### Prerequisites
- [EDL](https://github.com/bkerler/edl)
- Android fastboot tool
  ```
  sudo apt install fastboot
  ```

### Steps
- Enter Qualcom EDL mode using this [guide](https://wiki.postmarketos.org/wiki/Zhihe_series_LTE_dongles_(generic-zhihe)#How_to_enter_flash_mode)
- Backup required partitions

  The following files are required from the original firmware:
  
     - `fsc.bin`
     - `fsg.bin`
     - `modem.bin`
     - `modemst1.bin`
     - `modemst2.bin`
     - `persist.bin`
     - `sec.bin`

  Skip this step if these files are already present
  ```shell
  for n in fsc fsg modem modemst1 modemst2 persist sec; do
      edl r ${n} ${n}.bin
  done
  ```
- Install `aboot`
  ```shell
  edl w aboot aboot.mbn
  ```
- Reboot to fastboot
  ```shell
  edl e boot
  edl reset
  ```
- Flash firmware
  ```shell
  fastboot flash partition gpt_both0.bin
  fastboot flash aboot aboot.mbn
  fastboot flash hyp hyp.mbn
  fastboot flash rpm rpm.mbn
  fastboot flash sbl1 sbl1.mbn
  fastboot flash tz tz.mbn
  fastboot flash boot boot.bin
  fastboot flash rootfs rootfs.bin
  ```
- Restore original partitions
  ```shell
  for n in fsc fsg modem modemst1 modemst2 persist sec; do
      fastboot flash ${n} ${n}.bin
  done
  ```
- Reboot
  ```shell
  fastboot reboot
  ```

## Post-Install

- Default user

  | | |
  | ----- | ---- |
  | username | user |
  | password | 1 |

- WiFi hotspot (wlan0)

  A **hostapd**-based access point is started automatically at boot by the
  `openstick-hotspot.service` and `dnsmasq-openstick.service` units. Connect
  to it from any Wi-Fi client:

  | wlan0 | |
  | ----- | ---- |
  | ssid | Openstick |
  | password | openstick |
  | ip addr | 192.168.4.1 |
  | DHCP range | 192.168.4.10 - 192.168.4.250 |

  Hotspot clients reach the internet through the LTE uplink (wwan0) via NAT.

  Control it with:
  ```shell
  sudo systemctl start/stop openstick-hotspot.service
  sudo systemctl restart openstick-hotspot.service
  sudo systemctl status openstick-hotspot.service
  ```
  To change SSID/password/channel, edit `/etc/hostapd/hostapd.conf` and
  restart the service. See [`docs/hotspot.md`](docs/hotspot.md) for why the
  hotspot runs on hostapd instead of NetworkManager.

  > [!NOTE]
  > The wlan0 interface is intentionally left **unmanaged** by NetworkManager
  > so it never interferes with hostapd. If you want to join a Wi-Fi network
  > instead (client mode), stop the hotspot first, remove the
  > `unmanaged-devices=interface-name:wlan0` line from
  > `/etc/NetworkManager/NetworkManager.conf`, then use `nmcli` as usual.

- Device tuning (systemd services)

  A few oneshot units run at boot to make the modem stick behave on the
  MSM8916 SoC. They are installed by the image and live in
  [`configs/system/`](configs/system/) with their helper scripts in
  [`scripts/`](scripts/):

  | Unit | What it does |
  | ---- | ------------ |
  | `cleanup-wwan.service` | Moves the spurious per-slot modem links (`wwan1`..`wwan7`) into a `null` netns so only `wwan0` is visible to NetworkManager; restarts ModemManager if `wwan0` has no address yet. Runs [`/usr/local/sbin/cleanup-wwan`](scripts/cleanup-wwan). |
  | `disable-cpu-cores.service` | Powers off CPU cores 2 and 3 to save power on this 4-core SoC. |
  | `sms-gateway.service` | Runs the bundled [`sms-gateway`](https://github.com/mattboston/sms-gateway) REST API + WebUI. Sends/receives SMS over `/dev/wwan0at1`; see [SMS gateway](docs/sms-gateway.md) below. |

  ```shell
  systemctl status cleanup-wwan disable-cpu-cores
  systemctl disable --now disable-cpu-cores.service   # re-enable the extra cores, if ever needed
  ```

- SMS gateway

  The image bundles an `arm64` build of
  [sms-gateway](https://github.com/mattboston/sms-gateway) (built from the
  `src/sms-gateway` submodule by [`scripts/build_sms_gateway.sh`](scripts/build_sms_gateway.sh))
  and starts it at boot via `sms-gateway.service`. It exposes:

  | What | Where |
  | ---- | ----- |
  | WebUI + REST API | `http://<device>:5174` (login `admin` / `admin123` on first boot — change it!) |
  | config file | `/opt/sms-gateway/sms-gateway.conf` |
  | database | `/opt/sms-gateway/sms-gateway.db` (SQLite) |

  See [`docs/sms-gateway.md`](docs/sms-gateway.md) for how it coexists with
  ModemManager and how to build/update it.

  The modem on these sticks is a Qualcomm SoC rpmsg device, **not** a USB
  serial dongle, so there is no `/dev/ttyUSB*`. sms-gateway talks raw AT over
  the second modem AT port `/dev/wwan0at1`, which
  [`configs/udev/rules.d/99-sms-gateway.rules`](configs/udev/rules.d/99-sms-gateway.rules)
  reserves for it by excluding it from ModemManager. ModemManager keeps
  `/dev/wwan0at0` + `/dev/wwan0qmi0` for the cellular data connection
  (`wwan0`), so both run side by side.

  Control it with:

  ```shell
  systemctl status sms-gateway
  sudo systemctl restart sms-gateway
  sudo systemctl disable --now sms-gateway    # stop + disable at boot
  ```

  > [!NOTE]
  > The built-in service intentionally runs as `root` (it must open the
  > `root:root` `crw-------` device `/dev/wwan0at1`) and disables the upstream
  > unit's `ProtectSystem`/`ProtectHome` hardening so the SQLite database can
  > be created under `/opt/sms-gateway`.

- USB network (usb0)

  Managed by NetworkManager; exposes `192.168.5.1` to the host over the USB
  RNDIS/ECM gadget link.

- If your device is not based on **UZ801**, modify `/boot/extlinux/extlinux.conf` to use the correct devicetree
  ```shell
  sed -i 's/yiming-uz801v3/<BOARD>/' /boot/extlinux/extlinux.conf
  ```

  where `<BOARD>` is
     - `thwc-uf896` for **UF896** boards
     - `thwc-ufi001c` for **UFIxxx** boards
     - `jz01-45-v33` for **JZxxx** boards
     - `fy-mf800` for **MF800** boards

- To maximize the `rootfs` partition
  ```shell
  resize2fs /dev/disk/by-partlabel/rootfs
  ```

- To update the kernel of the `debian` image
  ```shell
  wget -O - http://mirror.postmarketos.org/postmarketos/<branch>/aarch64/linux-postmarketos-qcom-msm8916-<version>.apk \
          | tar xkzf - -C / --exclude=.PKGINFO --exclude=.SIGN* 2>/dev/null
  ```

  Specify the correct `<branch>` and `<version>` values.
