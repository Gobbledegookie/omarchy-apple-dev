# iPhone USB from Try Omarchy on Windows

Try Omarchy runs Omarchy inside a Windows-hosted QEMU VM. For iOS device
development, the iPhone must be visible inside the Omarchy guest as a real USB
device so `usbmuxd`, `pymobiledevice3`, and `xtool` can pair with it.

The reliable path is `usbipd-win` on Windows plus `usbip` inside Omarchy. Direct
QEMU `usb-host` passthrough can make `lsusb` show the phone, but `usbmuxd` may
still fail when it tries to switch the iPhone into its Apple communication
configuration.

## Windows host

Install usbipd-win:

```powershell
winget install --id dorssel.usbipd-win
```

Plug in the iPhone, unlock it, and find its USB bus id:

```powershell
usbipd list
```

Look for the Apple device, for example:

```text
4-6    05ac:12a8    Apple, Inc. iPhone    Not shared
```

Share the device. Replace `4-6` with the bus id printed on your machine:

```powershell
usbipd bind --busid 4-6 --force
```

Now start Try Omarchy normally. Do not also attach the iPhone through QEMU's USB
device menu or a QEMU `usb-host` option; usbipd will handle the connection.

## Omarchy guest

Install the usbip tools and load the virtual USB host controller:

```bash
sudo pacman -S --needed usbip
sudo modprobe vhci-hcd
```

List the USB devices exported by the Windows host:

```bash
usbip list -r 10.0.2.2
```

Attach the iPhone. Use the same bus id from `usbipd list`:

```bash
sudo usbip attach -r 10.0.2.2 -b 4-6
```

The phone may show **Trust This Computer?**. Keep it unlocked, tap **Trust**,
and enter the passcode.

Verify that Omarchy can see and pair with the phone:

```bash
lsusb | grep -i apple
sudo systemctl restart usbmuxd
sleep 2
~/pymobile3-venv/bin/pymobiledevice3 usbmux list
~/pymobile3-venv/bin/pymobiledevice3 lockdown pair
~/pymobile3-venv/bin/pymobiledevice3 lockdown info
```

`usbmux list` should print a JSON entry for the iPhone with
`"ConnectionType": "USB"`. After pairing, `lockdown info` should succeed.

## Run an app

From an `xtool` project directory:

```bash
/path/to/omarchy-apple-dev/device-run.sh
```

## Larger app installs

Small apps may install successfully while larger apps hang during install when
the iPhone is connected through `usbipd-win`. When this happens, `usbmuxd` can
log:

```text
device_control_input: ERROR (on device): asyncReadComplete, message was too large (65536 bytes, max = 65535)
device_control_input: Got unhandled payload type 4
```

Build a patched `usbmuxd` inside Omarchy with a USB/IP-safe mux size below the
rejected transfer boundary. The change is intentionally small:

```c
/* src/usb.h */
#define USBIPD_SAFE_MUX_SIZE 65535
#define USB_MTU USBIPD_SAFE_MUX_SIZE
```

```c
/* src/device.c */
#define DEV_MRU USBIPD_SAFE_MUX_SIZE
#define CONN_OUTBUF_SIZE USBIPD_SAFE_MUX_SIZE
```

Example build using `usbmuxd` 1.1.1:

```bash
NOCONFIGURE=1 ./autogen.sh
./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --sbindir=/usr/bin
make
make check
```

If building from distro packaging, apply the distro compatibility patches before
the USB/IP-safe size change.

Install the patched binary alongside the distro binary instead of replacing the
package-owned file:

```bash
sudo install -Dm755 src/usbmuxd /usr/local/sbin/usbmuxd-usbipd-safe
```

Add a systemd drop-in:

```bash
sudo mkdir -p /etc/systemd/system/usbmuxd.service.d
sudo tee /etc/systemd/system/usbmuxd.service.d/10-usbipd-safe.conf >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/local/sbin/usbmuxd-usbipd-safe --user usbmux --systemd
EOF
```

Restart `usbmuxd`:

```bash
sudo systemctl daemon-reload
sudo systemctl restart usbmuxd.service
```

Confirm systemd is using the patched binary:

```bash
systemctl status usbmuxd.service --no-pager
systemctl cat usbmuxd.service
```

Confirm the iPhone is still visible and paired:

```bash
~/pymobile3-venv/bin/pymobiledevice3 usbmux list
~/pymobile3-venv/bin/pymobiledevice3 lockdown info >/dev/null && echo paired
```

Retry the larger deploy, then check fresh logs:

```bash
journalctl -u usbmuxd --since "5 minutes ago" --no-pager
```

The expected result is no new `message was too large (65536 bytes, max = 65535)`
entry and no repeated `Got unhandled payload type 4` messages.

Rollback is just removing the drop-in and restarting the distro service:

```bash
sudo rm /etc/systemd/system/usbmuxd.service.d/10-usbipd-safe.conf
sudo systemctl daemon-reload
sudo systemctl restart usbmuxd.service
```

## Troubleshooting

If `lsusb` shows the iPhone but `pymobiledevice3 usbmux list` prints `[]`, check
the usbmuxd logs:

```bash
journalctl -u usbmuxd -n 30 --no-pager
```

If the log contains an error like this:

```text
Could not set configuration 4 for device ... LIBUSB_ERROR_OTHER
```

then the iPhone is visible to Linux but was not attached in a way usbmuxd can
use. Detach it from the QEMU/Try Omarchy USB menu if attached there, then use
the usbipd flow above.

If the bus id changes after unplugging the phone, rebooting Windows, or moving
to a different USB port, run `usbipd list` again on Windows and use the new bus
id for both `usbipd bind` and `usbip attach`.
