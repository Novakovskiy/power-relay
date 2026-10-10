# power-relay

UART power management service for Klipper. The service is designed to work with the [PowerRelay (ESP32)](https://github.com/Novakovskiy/PowerRelayESP32) relay.

## What it does

- Runs as a root systemd service at startup (`Restart=always`).
- Listens on the UART port from the config. The protocol is line-based text commands ending with `\n`, case-insensitive:
  - `power_off` — executes `systemctl poweroff`.
  - `power_on` — logged only.
  - any other line — warning is logged. No UART response is sent to incoming commands.
- When the system is shutting down on its own, the service receives SIGTERM and checks `systemctl list-jobs`:
  - `poweroff.target` / `halt.target` — sends `power_off` to UART;
  - `reboot.target` / `kexec.target` — sends nothing;
  - if shutdown was initiated by UART `power_off`, no notification is sent back.
- `power_off` is sent only if the UART port is open at shutdown time. If the service is reconnecting at that moment, no message is sent.
- If the UART port is unavailable, the service logs an error and retries opening it after `reconnect_delay_sec`.

## Structure

- The project is installed directly from `git clone`; files are not copied anywhere else.
- `power-relay-env/` — virtual environment created by the installer next to the project directory (for example `~/power-relay` and `~/power-relay-env`).

## Config

File: `power-relay.cfg` in the Klipper config directory (by default `~/printer_data/config/power-relay.cfg` for the user owning the project directory). If the file does not exist, the installer creates it from `config/power-relay.cfg.example`.

```ini
[serial]
# required
port = /dev/ttyUSB0
# optional
baudrate = 115200
read_timeout_sec = 1.0

[service]
# optional; DEBUG logs every command
log_level = INFO
reconnect_delay_sec = 3.0
```

Without `--config`, the service looks for the file in `/home/pi`, `/home/mks`, `/home/klipper` (`printer_data/config/power-relay.cfg`). The installer always passes the path explicitly.

## Installation

```bash
git clone https://github.com/Novakovskiy/power-relay.git
cd power-relay
bash install.sh
```

The script re-runs itself through `sudo` when not started as root. It:

1. Validates this is a `git clone` (`.git`, `pyproject.toml`, `src/power_relay` must exist).
2. Recreates `power-relay-env` and installs the package (Python 3.10+ required).
3. Creates `power-relay.cfg` if missing. Existing file is kept.
4. Adds `[update_manager power-relay]` to `moonraker.conf` (`type: git_repo`, `path`, `origin`, `primary_branch`, `managed_services: power-relay`, `install_script: install.sh`). If the section already exists, it is replaced.
5. Adds `power-relay` to `moonraker.asvc` so Moonraker can restart the service after updates.
6. Creates, enables, and starts `power-relay.service`.

For Moonraker updates, `origin` and branch are taken from the clone's git settings. Moonraker runs `git pull`, executes `install.sh`, and restarts the service. For this to work, the Moonraker user needs passwordless `sudo` (default in MainsailOS and KIAUH setups). After editing `moonraker.conf`, restart Moonraker.

## Uninstall

```bash
cd power-relay
bash uninstall.sh
```

1. Stops and removes `power-relay.service`.
2. Removes `[update_manager power-relay]` from `moonraker.conf`.
3. Removes `power-relay` from `moonraker.asvc`.
4. Removes `power-relay-env`.
5. Keeps `power-relay.cfg` and the project directory.

## Environment variables

You can override these for both `install.sh` and `uninstall.sh`:

```bash
SERVICE_NAME=power-relay \
INSTALL_DIR=/home/pi/power-relay \
VENV_DIR=/home/pi/power-relay-env \
RUN_USER=pi \
RUN_GROUP=pi \
KLIPPER_CONFIG_DIR=/home/pi/printer_data/config \
MOONRAKER_CONF_PATH=/home/pi/printer_data/config/moonraker.conf \
MOONRAKER_ASVC_PATH=/home/pi/printer_data/moonraker.asvc \
sudo -E bash install.sh
```

`RUN_USER` and `RUN_GROUP` control ownership of the venv and config file. By default, the owner of the project directory is used. The service itself always runs as root.

## Logs

```bash
journalctl -u power-relay.service -f
```
