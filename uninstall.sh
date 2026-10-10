#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-power-relay}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-${SCRIPT_DIR}}"
RUN_USER="${RUN_USER:-$(stat -c %U "${INSTALL_DIR}")}"
KLIPPER_CONFIG_DIR="${KLIPPER_CONFIG_DIR:-/home/$RUN_USER/printer_data/config}"
VENV_DIR="${VENV_DIR:-$(dirname "${INSTALL_DIR}")/power-relay-env}"
CONFIG_TARGET="${KLIPPER_CONFIG_DIR}/power-relay.cfg"
MOONRAKER_CONF_PATH="${MOONRAKER_CONF_PATH:-${KLIPPER_CONFIG_DIR}/moonraker.conf}"
MOONRAKER_ASVC_PATH="${MOONRAKER_ASVC_PATH:-$(dirname "${KLIPPER_CONFIG_DIR}")/moonraker.asvc}"
SYSTEMD_UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
UPDATE_SECTION_NAME="${UPDATE_SECTION_NAME:-update_manager ${SERVICE_NAME}}"

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
  fi
}

require_root "$@"

echo "Removing systemd service ${SERVICE_NAME}..."
if systemctl list-unit-files --type=service | grep -Fq "${SERVICE_NAME}.service"; then
  systemctl disable --now "${SERVICE_NAME}.service" || true
fi
rm -f "${SYSTEMD_UNIT_PATH}"
systemctl daemon-reload

if [[ -f "${MOONRAKER_CONF_PATH}" ]]; then
  echo "Removing [${UPDATE_SECTION_NAME}] from ${MOONRAKER_CONF_PATH}..."
  tmp="$(mktemp)"
  awk -v section="${UPDATE_SECTION_NAME}" '
    BEGIN { target = "[" section "]"; skip = 0 }
    /^\[[^]]+\]/ {
      if ($0 == target) { skip = 1; next }
      skip = 0
    }
    skip == 0 { print }
  ' "${MOONRAKER_CONF_PATH}" > "${tmp}"
  cat "${tmp}" > "${MOONRAKER_CONF_PATH}"
  rm -f "${tmp}"
fi

if [[ -f "${MOONRAKER_ASVC_PATH}" ]]; then
  echo "Removing ${SERVICE_NAME} from ${MOONRAKER_ASVC_PATH}..."
  tmp="$(mktemp)"
  awk -v service="${SERVICE_NAME}" '$0 != service { print }' "${MOONRAKER_ASVC_PATH}" > "${tmp}"
  cat "${tmp}" > "${MOONRAKER_ASVC_PATH}"
  rm -f "${tmp}"
fi

if [[ -d "${VENV_DIR}" ]]; then
  echo "Removing venv ${VENV_DIR}..."
  rm -rf "${VENV_DIR}"
fi

echo "Uninstall complete."
echo "Kept config file: ${CONFIG_TARGET}"
echo "Project directory ${INSTALL_DIR} was not removed."
