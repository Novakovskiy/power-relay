from __future__ import annotations

from configparser import ConfigParser
from dataclasses import dataclass
from pathlib import Path


DEFAULT_CONFIG_CANDIDATES = [
    Path("/home/pi/printer_data/config/power-relay.cfg"),
    Path("/home/mks/printer_data/config/power-relay.cfg"),
    Path("/home/klipper/printer_data/config/power-relay.cfg"),
]


@dataclass(frozen=True)
class SerialConfig:
    port: str
    baudrate: int = 115200
    read_timeout_sec: float = 1.0


@dataclass(frozen=True)
class ServiceConfig:
    log_level: str = "INFO"
    reconnect_delay_sec: float = 3.0


@dataclass(frozen=True)
class AppConfig:
    serial: SerialConfig
    service: ServiceConfig


def resolve_config_path(explicit_path: str | None) -> Path:
    if explicit_path:
        return Path(explicit_path)

    for candidate in DEFAULT_CONFIG_CANDIDATES:
        if candidate.exists():
            return candidate

    return DEFAULT_CONFIG_CANDIDATES[0]


def load_config(path: Path) -> AppConfig:
    if not path.exists():
        raise FileNotFoundError(
            f"Configuration file does not exist: {path}. "
            "Create it from power-relay.cfg.example in your Klipper config directory."
        )

    parser = ConfigParser()
    parser.read(path, encoding="utf-8")

    serial = SerialConfig(
        port=parser.get("serial", "port"),
        baudrate=parser.getint("serial", "baudrate", fallback=115200),
        read_timeout_sec=parser.getfloat("serial", "read_timeout_sec", fallback=1.0),
    )

    service = ServiceConfig(
        log_level=parser.get("service", "log_level", fallback="INFO").upper(),
        reconnect_delay_sec=parser.getfloat("service", "reconnect_delay_sec", fallback=3.0),
    )

    return AppConfig(serial=serial, service=service)
