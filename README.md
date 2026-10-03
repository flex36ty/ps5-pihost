# PS5 Pi Host

Use **Raspberry Pi OS Lite 64-bit, Bookworm or newer** with NetworkManager.
A 64 GB SD card has ample room. This runs the existing Python host; do not flash
the ESP32 binary to the Pi or its SD card.

## What this does

The Pi creates a Wi-Fi network for the PS5. Its DHCP server assigns the console
an IP address and tells it to use the Pi for DNS. DNS resolves
`manuals.playstation.net` to `192.168.4.1`, where the Python servers serve this
project over HTTP and HTTPS. Opening the PS5 User's Guide loads the local page.

The installer copies the site to `/home/ps5`, installs its dependencies,
generates a local self-signed TLS certificate, and creates systemd services.
It starts the host when installation finishes and enables it on every boot;
you do not need to leave a terminal or SSH session open.

You need a Raspberry Pi with hotspot-capable Wi-Fi, an SD card with Raspberry Pi OS, a suitable power
supply, and Internet access during installation. Use Ethernet for setup because
the Pi's built-in Wi-Fi becomes the hotspot. Set the Wi-Fi country to **US**
if using the Pi in the United States.

## Download

Clone this repository on the Pi, then run the installer over Ethernet SSH or a local console:

```bash
sudo apt-get update
sudo apt-get install -y git
git clone https://github.com/flex36ty/ps5-pihost.git ~/ps5-selfhost
cd ~/ps5-selfhost
sudo bash setup-pi5.sh
```

Despite its filename, the installer checks Wi-Fi capabilities rather than requiring a Pi 5. Other models have not been verified on hardware. This repository contains the script installation only.

The archive instructions below apply if you received the packaged tar.gz separately. Alternatively, download the repository ZIP, extract it, and upload its contents to the Pi.

## Install

1. Use Raspberry Pi Imager to install Raspberry Pi OS. Configure a username,
   password and SSH, and set your actual Wi-Fi country (or use `sudo raspi-config`
   after boot). Connect Ethernet for installation and remote access if possible.
2. Enable SSH in Imager, or run this from a terminal on the Pi:

   ```bash
   sudo systemctl enable --now ssh
   hostname -I
   ```

   From Windows PowerShell, connect using your username and the Pi's Ethernet
   IP address, for example `ssh yourusername@192.168.0.123`.
   Use the same credentials for SFTP on port 22; root login is not required.
3. Upload `ps5-pi5-selfhost.tar.gz` from the project's `releases` folder to your
   Pi user's home folder using SFTP. Extract and install it:

   ```bash
   mkdir -p ~/ps5-selfhost
   tar -xzf ~/ps5-pi5-selfhost.tar.gz -C ~/ps5-selfhost --strip-components=1
   cd ~/ps5-selfhost
   sudo bash setup-pi5.sh
   ```

   The archive contains a top-level folder, so `--strip-components=1` places
   the installer directly in `~/ps5-selfhost`. If you upload the whole project
   instead, run the installer from the folder containing `setup-pi5.sh`.

   Optionally choose a different name/password:

   ```bash
   sudo bash setup-pi5.sh --ssid PS5-Host --password 'YourChosenPassword'
   ```

4. Setup starts all services immediately and enables them at every boot.
   Run setup over Ethernet SSH or a local keyboard/screen: activation converts
   the built-in Wi-Fi to a hotspot and disconnects an SSH session using that
   Wi-Fi. Internet is needed for package installation, not normal hosting.
   Boot activation retries while the Wi-Fi adapter initializes. Setup checks
   all services and prints diagnostics if startup fails.

   For an existing installation, stop it before rerunning setup:

   ```bash
   sudo systemctl stop ps5-host.target
   cd ~/ps5-selfhost
   sudo bash setup-pi5.sh
   ```

## Services and automatic startup

`ps5-host.target` groups four services. It is a systemd target, not a terminal
session. Setup enables it under `multi-user.target` and starts it immediately.

| Unit | Purpose |
| --- | --- |
| `ps5-hotspot.service` | Activates the NetworkManager Wi-Fi access point; retries while the adapter initializes |
| `ps5-dns.service` | Provides DNS on port 53 and DHCP on UDP port 67 |
| `ps5-http.service` | Runs `/home/ps5/serve.py` on TCP port 80 |
| `ps5-https.service` | Runs `/home/ps5/serve_https.py` on TCP port 443 |

Both Python servers run at the same time. DNS waits for the hotspot to start.
The web and DNS processes restart on failure. Stopping the target stops all
four services; restarting it restarts them together.

Check boot enablement and service health:

```bash
systemctl is-enabled ps5-host.target
systemctl status ps5-host.target ps5-hotspot ps5-dns ps5-http ps5-https --no-pager
```

The target should be `enabled`, the hotspot `active (exited)`, and the DNS and
web services `active (running)`. The hotspot uses a one-shot activation command,
so `active (exited)` is normal. Reboot and repeat these checks to confirm boot
startup on your Pi.

## Connect the PS5

| Setting | Value |
| --- | --- |
| Wi-Fi network | PS5-Host |
| Password | ps5offline (unless changed during setup) |
| IP address | Automatic |
| DNS | Automatic |
| DHCP hostname | Do not specify |
| MTU / Proxy | Automatic / Do not use |
| Pi hotspot IP | 192.168.4.1 |
| DHCP pool | 192.168.4.100–192.168.4.150, 12-hour lease |

Open User's Guide and proceed past the local certificate prompt if offered.
DNS directs manuals.playstation.net to the Pi; HTTPS handles the guide request.
R2 sends nanoDNS, ShadowMount Plus, then kstuff. The hotspot has no configured
Internet sharing, so the Internet/PSN connection test can fail while the local
page works. Ethernet remains available for administering the Pi.

After the exploit reaches the ELF loader, R2 sends these files in order:

1. `payloads/nanodns.elf`
2. `payloads/shadowmountplus.elf`
3. `payloads/kstuff.elf`

Keep these exact filenames and capitalization. The order is defined in
`src/kexp.js`; adding another ELF file to the folder does not automatically
add it to the R2 sequence. `etaHEN.elf` is not part of this sequence.

## Manage and test

```bash
sudo systemctl start ps5-host.target
sudo systemctl stop ps5-host.target
sudo systemctl restart ps5-host.target
sudo systemctl status ps5-hotspot ps5-dns ps5-http ps5-https
sudo journalctl -u ps5-hotspot -u ps5-dns -u ps5-https -f
```

From a computer joined to the hotspot:

```bash
nslookup manuals.playstation.net 192.168.4.1
curl -k https://192.168.4.1/
```

Use `/home/ps5` for web files and payloads. Restart web services after changing
Python files; close/reopen the PS5 guide after changing JavaScript. To reinstall,
stop the target and rerun this installer. Do not run the generic container
`setup-ps5.sh` on this hotspot installation: it configures a different DNS service.

The installer creates a dedicated NetworkManager profile and a dedicated
`ps5-dns` service. It does not change Ethernet profiles, install NetworkManager
over another network stack, replace existing DNS services, or add NAT/firewall
rules. If another DNS/DHCP service occupies the required ports, resolve that
conflict first. When a firewall is enabled, allow UDP 67, TCP/UDP 53 and TCP
80/443 on the hotspot interface only. Keep the host on your local network.

## Troubleshooting

### Hotspot missing or failed at boot

Collect these logs before manually starting the host, so the boot failure is
visible:

```bash
sudo journalctl -b -u ps5-hotspot.service -u NetworkManager.service --no-pager -n 100
nmcli device status
rfkill list
```

Set your Wi-Fi country through `sudo raspi-config` if it was not configured.
The default interface is `wlan0`; use `--interface NAME` with the installer if
your Wi-Fi adapter uses another name. After resolving the reported error:

```bash
sudo systemctl restart ps5-host.target
```

### Works after manual startup but not after reboot

Check enablement and inspect the boot logs:

```bash
systemctl is-enabled ps5-host.target
sudo journalctl -b -u ps5-hotspot -u ps5-dns -u ps5-http -u ps5-https --no-pager -n 100
```

If disabled, run `sudo systemctl enable --now ps5-host.target`. If already
enabled, the logs identify the startup failure; enabling again will not fix
that underlying error. The updated installer includes Wi-Fi activation retries.

### Connected to Wi-Fi but the page does not load

Keep the PS5 IP and DNS settings automatic. From a computer connected to
`PS5-Host`, test:

```bash
nslookup manuals.playstation.net 192.168.4.1
curl -k https://192.168.4.1/
```

On Windows, use `curl.exe -k https://192.168.4.1/`. DNS should return
`192.168.4.1` and curl should return the page HTML. The PS5 guide needs HTTPS;
a successful port 80 test alone does not verify port 443. The `-k` option here
allows testing the local self-signed certificate.

### Update files or inspect installation paths

| Path | Contents |
| --- | --- |
| `/home/ps5` | Installed website, scripts and payloads |
| `/etc/ps5-host` | Certificate, private key, DNS configuration and profile UUID |
| `/etc/systemd/system/ps5-*` | Service and target definitions |
| `/usr/local/sbin/ps5-start-hotspot` | Wi-Fi activation helper |
| `/var/backups/ps5-pi` | Files backed up during setup |

Upload updates to your user home folder and rerun setup as above; the installed
folder may require sudo to modify. After directly editing Python files, run
`sudo systemctl restart ps5-http ps5-https`. Static file changes do not require
a Python restart, but close and reopen the guide to load updated JavaScript.

## Disable the host

```bash
sudo systemctl disable --now ps5-host.target
```

This stops all four component services. The hotspot profile does not auto-connect
on its own. Existing Wi-Fi profiles are retained; select one with `nmtui` if
needed. Project files, certificates and backups are preserved.

Pi hardware, Wi-Fi association and PS5 execution require a real-device test.
Installer syntax/configuration checks do not substitute for that test.
