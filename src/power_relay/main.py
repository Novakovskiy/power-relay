from __future__ import annotations

import argparse
import logging
import signal
import sys
from pathlib import Path

from .config import load_config, resolve_config_path
from .service import UartPowerService


LOGGER = logging.getLogger("power_relay")


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Power UART service for Klipper")
    parser.add_argument(
        "--config",
        help="Path to power-relay.cfg. Defaults to common Klipper config locations.",
    )
    return parser


def configure_logging(level: str) -> None:
    logging.basicConfig(
        level=getattr(logging, level, logging.INFO),
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )


def main() -> int:
    parser = build_arg_parser()
    args = parser.parse_args()

    config_path = resolve_config_path(args.config)
    try:
        config = load_config(config_path)
    except Exception as exc:
        print(f"[power-relay] Failed to load config ({config_path}): {exc}", file=sys.stderr)
        return 2

    configure_logging(config.service.log_level)
    LOGGER.info("Using config file: %s", config_path)

    service = UartPowerService(config=config)

    def _handle_signal(sig: int, _frame: object) -> None:
        LOGGER.info("Received signal %s, stopping...", sig)
        service.stop()

    signal.signal(signal.SIGINT, _handle_signal)
    signal.signal(signal.SIGTERM, _handle_signal)

    service.run_forever()
    LOGGER.info("Stopped.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
