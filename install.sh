#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${SERVICE_NAME:-power-relay}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-${SCRIPT_DIR}}"
RUN_USER="${RUN_USER:-$(stat -c %U "${INSTALL_DIR}")}"
RUN_GROUP="${RUN_GROUP:-$(id -gn "${RUN_USER}")}"
KLIPPER_CONFIG_DIR="${KLIPPER_CONFIG_DIR:-/home/$RUN_USER/printer_data/config}"
VENV_DIR="${VENV_DIR:-$(dirname "${INSTALL_DIR}")/power-relay-env}"
CONFIG_TARGET="${KLIPPER_CONFIG_DIR}/power-relay.cfg"
MOONRAKER_CONF_PATH="${MOONRAKER_CONF_PATH:-${KLIPPER_CONFIG_DIR}/moonraker.conf}"
SYSTEMD_UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
UPDATE_SECTION_NAME="${UPDATE_SECTION_NAME:-update_manager ${SERVICE_NAME}}"

REPO_ORIGIN="${REPO_ORIGIN:-$(git -C "${INSTALL_DIR}" config --get remote.origin.url 2>/dev/null || true)}"
PRIMARY_BRANCH="${PRIMARY_BRANCH:-$(
  git -C "${INSTALL_DIR}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
    | sed 's#^origin/##' \
    || true
)}"

if [[ -z "${REPO_ORIGIN}" ]]; then
  REPO_ORIGIN="https://github.com/Novakovskiy/power-relay.git"
fi

if [[ -z "${PRIMARY_BRANCH}" ]]; then
  PRIMARY_BRANCH="main"
fi

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    exec sudo -E bash "${BASH_SOURCE[0]}" "$@"
  fi
}

pick_python() {
  local candidates=(python3.13 python3.12 python3.11 python3.10 python3)
  for py in "${candidates[@]}"; do
    if command -v "$py" >/dev/null 2>&1; then
      if "$py" -c 'import sys; raise SystemExit(0 if (3,10)<=sys.version_info else 1)'; then
        echo "$py"
        return 0
      fi
    fi
  done
  echo "No compatible Python found (need 3.10+)." >&2
  exit 1
}

validate_source_tree() {
  if [[ ! -d "${INSTALL_DIR}/.git" ]]; then
    echo "Expected git clone at ${INSTALL_DIR} (missing .git)." >&2
    exit 1
  fi
  if [[ ! -f "${INSTALL_DIR}/pyproject.toml" || ! -d "${INSTALL_DIR}/src/power_relay" ]]; then
    echo "Invalid project structure in ${INSTALL_DIR}. Run from power-relay repo root." >&2
    exit 1
  fi
}

install_venv() {
  local py="$1"
  echo "Preparing venv at ${VENV_DIR} with ${py}..."
  rm -rf "${VENV_DIR}"
  "$py" -m venv "${VENV_DIR}"
  "${VENV_DIR}/bin/python" -m pip install --upgrade pip
  "${VENV_DIR}/bin/pip" install "${INSTALL_DIR}"
  chown -R "${RUN_USER}:${RUN_GROUP}" "${VENV_DIR}"
}

install_config() {
  echo "Installing config in ${KLIPPER_CONFIG_DIR}..."
  mkdir -p "${KLIPPER_CONFIG_DIR}"
  if [[ ! -f "${CONFIG_TARGET}" ]]; then
    cp "${INSTALL_DIR}/config/power-relay.cfg.example" "${CONFIG_TARGET}"
    chown "${RUN_USER}:${RUN_GROUP}" "${CONFIG_TARGET}"
    chmod 640 "${CONFIG_TARGET}"
    echo "Created ${CONFIG_TARGET}. Please edit it before production use."
  else
    echo "Config already exists: ${CONFIG_TARGET}. Keeping existing file."
  fi
}

remove_moonraker_update_section() {
  if [[ ! -f "${MOONRAKER_CONF_PATH}" ]]; then
    return 0
  fi

  local tmp
  tmp="$(mktemp)"
  awk -v section="${UPDATE_SECTION_NAME}" '
    BEGIN {
      target = "[" section "]"
      skip = 0
    }
    /^\[[^]]+\]/ {
      if ($0 == target) {
        skip = 1
        next
      }
      if (skip == 1) {
        skip = 0
      }
    }
    skip == 0 { print }
  ' "${MOONRAKER_CONF_PATH}" > "${tmp}"
  mv "${tmp}" "${MOONRAKER_CONF_PATH}"
}

install_moonraker_update_section() {
  echo "Updating ${MOONRAKER_CONF_PATH}..."
  mkdir -p "$(dirname "${MOONRAKER_CONF_PATH}")"
  if [[ ! -f "${MOONRAKER_CONF_PATH}" ]]; then
    touch "${MOONRAKER_CONF_PATH}"
  fi

  remove_moonraker_update_section
  cat >> "${MOONRAKER_CONF_PATH}" <<EOF

[${UPDATE_SECTION_NAME}]
type: git_repo
path: ${INSTALL_DIR}
origin: ${REPO_ORIGIN}
primary_branch: ${PRIMARY_BRANCH}
managed_services:
  ${SERVICE_NAME}
install_script: install.sh
EOF

  chown "${RUN_USER}:${RUN_GROUP}" "${MOONRAKER_CONF_PATH}" || true
  echo "Added [${UPDATE_SECTION_NAME}] to ${MOONRAKER_CONF_PATH}."
}

install_systemd_unit() {
  echo "Installing systemd service ${SERVICE_NAME}..."
  cat > "${SYSTEMD_UNIT_PATH}" <<EOF
[Unit]
Description=Power UART service for Klipper
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=${VENV_DIR}/bin/power-relay --config ${CONFIG_TARGET}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

  chmod 644 "${SYSTEMD_UNIT_PATH}"
  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.service"
  systemctl --no-pager --full status "${SERVICE_NAME}.service" || true
}

main() {
  require_root
  validate_source_tree
  local py_bin
  py_bin="$(pick_python)"
  echo "Using Python interpreter: ${py_bin}"
  install_venv "${py_bin}"
  install_config
  install_moonraker_update_section
  install_systemd_unit
  echo "Installation complete."
  echo "Project dir: ${INSTALL_DIR}"
  echo "Edit config (kept on uninstall): ${CONFIG_TARGET}"
  echo "Logs: journalctl -u ${SERVICE_NAME}.service -f"
}

main "$@"
