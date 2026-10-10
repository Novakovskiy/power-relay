from __future__ import annotations

import logging
import subprocess
import time
from threading import Event

import serial
from serial import SerialException

from .config import AppConfig


LOGGER = logging.getLogger("power_relay.service")

CMD_POWER_ON = "power_on"
CMD_POWER_OFF = "power_off"


def detect_shutdown_kind() -> str:
    """Return 'poweroff', 'reboot' or 'unknown' based on pending systemd jobs."""
    try:
        out = subprocess.run(
            ["systemctl", "list-jobs", "--no-legend"],
            capture_output=True,
            text=True,
            timeout=5,
            check=False,
        ).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        LOGGER.error("Failed to query systemd jobs: %s", exc)
        return "unknown"

    if "reboot.target" in out or "kexec.target" in out:
        return "reboot"
    if "poweroff.target" in out or "halt.target" in out:
        return "poweroff"
    if "shutdown.target" in out:
        return "poweroff"
    return "unknown"


class UartPowerService:
    def __init__(self, config: AppConfig) -> None:
        self._config = config
        self._stop_event = Event()
        self._shutdown_kind = "unknown"
        self._shutdown_requested_by_uart = False

    def stop(self) -> None:
        """Called on SIGTERM/SIGINT. Must be called before the system is down."""
        if not self._stop_event.is_set():
            self._shutdown_kind = self._detect_shutdown_kind_with_retry()
            LOGGER.info("Stopping, system shutdown kind: %s", self._shutdown_kind)
        self._stop_event.set()

    @staticmethod
    def _detect_shutdown_kind_with_retry() -> str:
        # On some shutdown paths (for example from web UI), SIGTERM can arrive
        # slightly before shutdown jobs are visible in systemd.
        for _ in range(10):
            kind = detect_shutdown_kind()
            if kind != "unknown":
                return kind
            time.sleep(0.2)
        return "unknown"

    def run_forever(self) -> None:
        serial_cfg = self._config.serial
        reconnect_delay = self._config.service.reconnect_delay_sec

        while not self._stop_event.is_set():
            try:
                LOGGER.info("Opening UART %s @ %d", serial_cfg.port, serial_cfg.baudrate)
                with serial.Serial(
                    port=serial_cfg.port,
                    baudrate=serial_cfg.baudrate,
                    timeout=serial_cfg.read_timeout_sec,
                    write_timeout=serial_cfg.read_timeout_sec,
                ) as uart:
                    self._run_connected(uart)
                    self._notify_shutdown(uart)
            except SerialException as exc:
                LOGGER.error("UART connection error: %s", exc)
            except OSError as exc:
                LOGGER.error("UART OS error: %s", exc)

            if not self._stop_event.is_set():
                time.sleep(reconnect_delay)

    def _run_connected(self, uart: serial.Serial) -> None:
        while not self._stop_event.is_set():
            raw = uart.readline()
            if not raw:
                continue

            command = raw.decode("utf-8", errors="replace").strip().lower()
            if not command:
                continue

            LOGGER.debug("Received command: %s", command)
            if command == CMD_POWER_OFF:
                self._request_system_poweroff()
            elif command == CMD_POWER_ON:
                LOGGER.info("Received %s", CMD_POWER_ON)
            else:
                LOGGER.warning("Unknown command: %s", command)

    def _request_system_poweroff(self) -> None:
        if self._shutdown_requested_by_uart:
            return
        LOGGER.info("Received %s, shutting down the system", CMD_POWER_OFF)
        self._shutdown_requested_by_uart = True
        try:
            subprocess.run(["systemctl", "poweroff"], check=True, timeout=10)
        except (OSError, subprocess.SubprocessError) as exc:
            self._shutdown_requested_by_uart = False
            LOGGER.error("Failed to power off the system: %s", exc)

    def _notify_shutdown(self, uart: serial.Serial) -> None:
        # Don't echo power_off back if the peer itself requested it.
        if self._shutdown_kind != "poweroff" or self._shutdown_requested_by_uart:
            return
        LOGGER.info("System is powering off, sending %s", CMD_POWER_OFF)
        try:
            uart.write(f"{CMD_POWER_OFF}\n".encode("utf-8"))
            uart.flush()
        except SerialException as exc:
            LOGGER.error("Failed to notify UART about shutdown: %s", exc)
