#!/bin/bash
# Shared MikroTik SSH bootstrap for deployment/scripts/*.sh helpers.
# Not intended to be executed directly; source from sibling scripts.
#
# Defines: REPO_ROOT, DOCKER_ENV_FILE, HOST, PORT, USER_NAME, SSH_CONN_OPTS,
#          _trim_env_value, _try_auto_install_sshpass, _clear_stale_known_host_for_router, _run_ssh
#
# Caller must set SCRIPT_DIR to the directory containing this file before sourcing.

set -e

GREEN=$(printf '\033[0;32m')
YELLOW=$(printf '\033[1;33m')
BLUE=$(printf '\033[0;34m')
RED=$(printf '\033[0;31m')
NC=$(printf '\033[0m')

# REPO_ROOT is the lokalfi-captive-portal checkout (flash files + deployment/docker/.env).
# mikrotik-setup sets MIKROTIK_PORTAL_ROOT. Portal npm scripts leave it unset (layout: scripts/../..).
if [ -n "${MIKROTIK_PORTAL_ROOT:-}" ]; then
  REPO_ROOT="${MIKROTIK_PORTAL_ROOT}"
else
  REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
fi
DOCKER_ENV_FILE="${REPO_ROOT}/deployment/docker/.env"

_trim_env_value() {
  local v="$1"
  v="${v//$'\r'/}"
  if [[ "$v" =~ ^\".*\"$ ]]; then v="${v#\"}"; v="${v%\"}"; fi
  if [[ "$v" =~ ^\'.*\'$ ]]; then v="${v#\'}"; v="${v%\'}"; fi
  printf '%s' "$v"
}

_try_auto_install_sshpass() (
  set +e
  if command -v sshpass >/dev/null 2>&1; then
    exit 0
  fi

  printf "%s\n" "${BLUE}[INFO] sshpass not found; attempting install (set MIKROTIK_AUTO_INSTALL_SSHPASS=false to skip) ...${NC}"

  uname_s="$(uname -s 2>/dev/null || printf unknown)"

  case "$uname_s" in
    Darwin)
      if ! command -v brew >/dev/null 2>&1; then
        printf "%s\n" "${YELLOW}[WARNING] Homebrew not found; install https://brew.sh then brew install sshpass.${NC}"
        exit 1
      fi
      if brew install sshpass >/dev/null 2>&1; then
        :
      elif brew tap esolitos/ipa >/dev/null 2>&1 && brew install sshpass >/dev/null 2>&1; then
        :
      elif brew install hudochenkov/sshpass/sshpass >/dev/null 2>&1; then
        :
      else
        brew install sshpass 2>&1 || true
      fi
      ;;
    Linux)
      if command -v apt-get >/dev/null 2>&1; then
        sudo apt-get update -qq && sudo apt-get install -y sshpass
      elif command -v dnf >/dev/null 2>&1; then
        sudo dnf install -y sshpass
      elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y sshpass
      elif command -v pacman >/dev/null 2>&1; then
        sudo pacman -S --noconfirm sshpass
      elif command -v zypper >/dev/null 2>&1; then
        sudo zypper install -y sshpass
      elif command -v apk >/dev/null 2>&1; then
        sudo apk add sshpass
      elif command -v nix-env >/dev/null 2>&1; then
        nix-env -iA nixpkgs.sshpass
      else
        printf "%s\n" "${YELLOW}[WARNING] No supported package manager found for Linux.${NC}"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      if command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm sshpass 2>/dev/null || pacman -S --noconfirm sshpass 2>/dev/null || true
      fi
      if ! command -v sshpass >/dev/null 2>&1 && command -v choco >/dev/null 2>&1; then
        choco install sshpass -y
      fi
      if ! command -v sshpass >/dev/null 2>&1 && command -v scoop >/dev/null 2>&1; then
        scoop install sshpass
      fi
      ;;
    *)
      printf "%s\n" "${YELLOW}[WARNING] Auto-install not mapped for OS: ${uname_s}${NC}"
      ;;
  esac

  if command -v sshpass >/dev/null 2>&1; then
    printf "%s\n" "${GREEN}[SUCCESS] sshpass is now available.${NC}"
    exit 0
  fi
  exit 1
)

# mikrotik_ssh_bootstrap [optional_host_override]
# Sets HOST, PORT, USER_NAME, MIKROTIK_PASSWORD (from env / .env), SSH_CONN_OPTS; defines _run_ssh.
mikrotik_ssh_bootstrap() {
  local host_override="${1:-}"

  PASSWORD_FROM_DOCKER_ENV=false
  local mi_private="" mi_public="" mi_mgmt_ip=""

  if [ -f "$DOCKER_ENV_FILE" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ -z "${line// /}" ]] && continue
      if [[ "$line" =~ ^MIKROTIK_PASSWORD= ]]; then
        mi_private="$(_trim_env_value "${line#MIKROTIK_PASSWORD=}")"
      elif [[ "$line" =~ ^NEXT_PUBLIC_MIKROTIK_PASSWORD= ]]; then
        mi_public="$(_trim_env_value "${line#NEXT_PUBLIC_MIKROTIK_PASSWORD=}")"
      elif [[ "$line" =~ ^NEXT_PUBLIC_MIKROTIK_MANAGEMENT_IP= ]]; then
        mi_mgmt_ip="$(_trim_env_value "${line#NEXT_PUBLIC_MIKROTIK_MANAGEMENT_IP=}")"
      fi
    done < "$DOCKER_ENV_FILE"
  fi

  if [ -z "${MIKROTIK_PASSWORD:-}" ]; then
    if [ -n "$mi_private" ]; then
      MIKROTIK_PASSWORD="$mi_private"
      PASSWORD_FROM_DOCKER_ENV=true
    elif [ -n "$mi_public" ]; then
      MIKROTIK_PASSWORD="$mi_public"
      PASSWORD_FROM_DOCKER_ENV=true
    fi
    export MIKROTIK_PASSWORD
  fi

  DEFAULT_MIKROTIK_IP="192.168.10.1"
  if [ -n "$host_override" ]; then
    HOST="$host_override"
  elif [ -n "${MIKROTIK_HOST:-}" ]; then
    HOST="$MIKROTIK_HOST"
  elif [ -n "$mi_mgmt_ip" ]; then
    HOST="$mi_mgmt_ip"
  else
    HOST="$DEFAULT_MIKROTIK_IP"
  fi

  USER_NAME="${MIKROTIK_USER:-admin}"
  PORT="${MIKROTIK_PORT:-22}"

  if [ -n "${MIKROTIK_PASSWORD:-}" ] && ! command -v sshpass >/dev/null 2>&1; then
    if [ "${MIKROTIK_AUTO_INSTALL_SSHPASS:-true}" != "false" ]; then
      _try_auto_install_sshpass || true
    fi
  fi

  if [ -n "${MIKROTIK_PASSWORD:-}" ] && ! command -v sshpass >/dev/null 2>&1; then
    if [ "$PASSWORD_FROM_DOCKER_ENV" = true ]; then
      printf "%s\n" "${RED}[ERROR] Loaded MikroTik password from ${DOCKER_ENV_FILE} but sshpass is not available.${NC}"
      printf "%s\n" "${BLUE}[INFO] Install sshpass or unset password and use interactive SSH.${NC}"
      exit 1
    fi
    printf "%s\n" "${YELLOW}[WARNING] MIKROTIK_PASSWORD is set but sshpass was not found; SSH will prompt for a password.${NC}"
  fi

  if [ "$PASSWORD_FROM_DOCKER_ENV" = true ]; then
    printf "%s\n" "${BLUE}[INFO] Using MikroTik password from ${DOCKER_ENV_FILE}${NC}"
  fi

  printf "%s\n" "${BLUE}[INFO] Router ${HOST} (${USER_NAME}, port ${PORT})${NC}"

  SSH_MUX_CONTROL_PATH="/tmp/lmf-mikrotik-%C"
  SSH_CONN_OPTS=( -o StrictHostKeyChecking=accept-new )
  if [ "${MIKROTIK_SSH_NO_MUX:-}" != "true" ]; then
    SSH_CONN_OPTS+=( -o ControlMaster=auto -o "ControlPath=${SSH_MUX_CONTROL_PATH}" -o ControlPersist=120 )
  fi

  _close_ssh_mux() {
    if [ "${MIKROTIK_SSH_NO_MUX:-}" = "true" ]; then
      return 0
    fi
    ssh -p "$PORT" -o "ControlPath=${SSH_MUX_CONTROL_PATH}" -O exit "${USER_NAME}@${HOST}" 2>/dev/null || true
  }
  trap _close_ssh_mux EXIT INT TERM

  _clear_stale_known_host_for_router() {
    if ! command -v ssh-keygen >/dev/null 2>&1; then
      printf "%s\n" "${YELLOW}[WARNING] ssh-keygen not in PATH; skipping known_hosts refresh.${NC}"
      return 0
    fi
    printf "%s\n" "${BLUE}[INFO] Refreshing SSH known_hosts for ${HOST} ...${NC}"
    ssh-keygen -R "$HOST" >/dev/null 2>&1 || true
    if [ "$PORT" != "22" ]; then
      ssh-keygen -R "[${HOST}]:${PORT}" >/dev/null 2>&1 || true
    fi
  }

  _clear_stale_known_host_for_router

  _run_ssh() {
    local remote_cmd="$1"
    if [ -n "${MIKROTIK_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
      SSHPASS="$MIKROTIK_PASSWORD" sshpass -e ssh -p "$PORT" \
        "${SSH_CONN_OPTS[@]}" \
        "${USER_NAME}@${HOST}" "$remote_cmd"
    else
      ssh -p "$PORT" \
        "${SSH_CONN_OPTS[@]}" \
        "${USER_NAME}@${HOST}" "$remote_cmd"
    fi
  }
}
