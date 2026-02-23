#!/usr/bin/env bash
set -euo pipefail

# Steam Link HDMI + Controller daemon for Raspberry Pi OS Lite 64-bit.
# - Installs required packages (optional via --install)
# - Starts Steam Link automatically when an HDMI display is active
# - Sends CEC "power on" when a game controller appears
# - Stops Steam Link when display is turned off/disconnected to free RAM

POLL_SECONDS="${POLL_SECONDS:-2}"
LOG_TAG="steamlink-hdmi-daemon"
STEAMLINK_BIN="${STEAMLINK_BIN:-/usr/bin/steamlink}"
STEAMLINK_ARGS="${STEAMLINK_ARGS:---kms --fullscreen}"
STEAMLINK_LOG="${STEAMLINK_LOG:-/tmp/steamlink-daemon.log}"
# Optional überschreiben, z. B. STEAMLINK_USER=alex
STEAMLINK_USER="${STEAMLINK_USER:-}"
STEAMLINK_PID=""
LAST_CONTROLLER_SIG=""

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  logger -t "$LOG_TAG" -- "$*" 2>/dev/null || true
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

install_deps() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Bitte als root mit --install ausführen." >&2
    exit 1
  fi

  apt-get update
  apt-get install -y steamlink cec-utils jq
}

resolve_run_user() {
  # Wenn Script bereits als normaler User läuft, diesen verwenden.
  if [[ "${EUID}" -ne 0 ]]; then
    id -un
    return 0
  fi

  # Falls explizit gesetzt.
  if [[ -n "$STEAMLINK_USER" ]]; then
    echo "$STEAMLINK_USER"
    return 0
  fi

  # Typischer erster Raspberry-User (UID 1000)
  local user_1000
  user_1000="$(awk -F: '$3==1000 {print $1; exit}' /etc/passwd || true)"
  if [[ -n "$user_1000" ]]; then
    echo "$user_1000"
    return 0
  fi

  return 1
}

connected_hdmi_connectors() {
  local found=0
  for status_file in /sys/class/drm/card*-HDMI-A-*/status; do
    [[ -e "$status_file" ]] || continue
    if [[ "$(<"$status_file")" == "connected" ]]; then
      found=1
      basename "$(dirname "$status_file")"
    fi
  done
  return $((1 - found))
}

# Returns 0 if at least one display is active/on.
display_is_active() {
  # Fast path: HDMI connector connected
  if connected_hdmi_connectors >/dev/null; then
    return 0
  fi

  # Fallback: vcgencmd display power status (older firmware stacks)
  if need_cmd vcgencmd; then
    local out
    out="$(vcgencmd display_power 2>/dev/null || true)"
    [[ "$out" =~ display_power=1 ]] && return 0
  fi

  return 1
}

# Uses CEC to power on TV/monitor if supported.
send_cec_power_on() {
  if ! need_cmd cec-client; then
    return 0
  fi

  # "on 0" -> power on TV (logical address 0)
  echo 'on 0' | cec-client -s -d 1 >/dev/null 2>&1 || true
  # Set active source so input switches to Raspberry Pi
  echo 'as' | cec-client -s -d 1 >/dev/null 2>&1 || true
}

controller_signature() {
  local sig
  sig=""

  # USB gamepads
  while IFS= read -r line; do
    sig+="$line;"
  done < <(ls /dev/input/js* 2>/dev/null || true)

  # Bluetooth connected devices (if bluetoothctl exists)
  if need_cmd bluetoothctl; then
    while IFS= read -r dev; do
      sig+="$dev;"
    done < <(bluetoothctl devices Connected 2>/dev/null | awk '{print $2}' || true)
  fi

  printf '%s' "$sig"
}

pick_sdl_display_index() {
  local connectors=()
  local c
  while IFS= read -r c; do
    connectors+=("$c")
  done < <(connected_hdmi_connectors || true)

  if (( ${#connectors[@]} == 0 )); then
    echo 0
    return
  fi

  # cardX-HDMI-A-1 => index 0, HDMI-A-2 => index 1
  local name="${connectors[0]}"
  local num="${name##*-}"
  if [[ "$num" =~ ^[0-9]+$ ]]; then
    echo $((num - 1))
  else
    echo 0
  fi
}

start_steamlink() {
  if [[ -n "$STEAMLINK_PID" ]] && kill -0 "$STEAMLINK_PID" 2>/dev/null; then
    return
  fi

  if [[ ! -x "$STEAMLINK_BIN" ]]; then
    log "Steam Link nicht gefunden unter $STEAMLINK_BIN"
    return
  fi

  local run_user
  if ! run_user="$(resolve_run_user)"; then
    log "Kein geeigneter Nicht-Root-User gefunden. Setze STEAMLINK_USER=deinuser"
    return
  fi

  local display_index
  display_index="$(pick_sdl_display_index)"

  log "Starte Steam Link als User '$run_user' auf Display-Index $display_index"

  # shellcheck disable=SC2206
  local args=( $STEAMLINK_ARGS )

  if [[ "${EUID}" -eq 0 ]]; then
    runuser -u "$run_user" -- env SDL_VIDEO_FULLSCREEN_DISPLAY="$display_index" \
      "$STEAMLINK_BIN" "${args[@]}" >"$STEAMLINK_LOG" 2>&1 &
  else
    SDL_VIDEO_FULLSCREEN_DISPLAY="$display_index" \
      "$STEAMLINK_BIN" "${args[@]}" >"$STEAMLINK_LOG" 2>&1 &
  fi

  STEAMLINK_PID="$!"

  sleep 1
  if ! kill -0 "$STEAMLINK_PID" 2>/dev/null; then
    log "Steam Link ist direkt wieder beendet. Siehe Log: $STEAMLINK_LOG"
    STEAMLINK_PID=""
  fi
}

stop_steamlink() {
  if [[ -z "$STEAMLINK_PID" ]]; then
    return
  fi

  if kill -0 "$STEAMLINK_PID" 2>/dev/null; then
    log "Stoppe Steam Link (Display aus/getrennt)"
    kill "$STEAMLINK_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$STEAMLINK_PID" 2>/dev/null || true
  fi
  STEAMLINK_PID=""
}

cleanup() {
  stop_steamlink
}
trap cleanup EXIT INT TERM

main_loop() {
  log "Daemon gestartet (POLL_SECONDS=${POLL_SECONDS})"

  while true; do
    local current_sig
    current_sig="$(controller_signature)"

    if [[ -n "$current_sig" && "$current_sig" != "$LAST_CONTROLLER_SIG" ]]; then
      log "Controller erkannt -> sende CEC Power-On"
      send_cec_power_on
    fi
    LAST_CONTROLLER_SIG="$current_sig"

    if display_is_active; then
      start_steamlink
    else
      stop_steamlink
    fi

    # If steamlink exited unexpectedly, clear PID so we can relaunch later.
    if [[ -n "$STEAMLINK_PID" ]] && ! kill -0 "$STEAMLINK_PID" 2>/dev/null; then
      STEAMLINK_PID=""
    fi

    sleep "$POLL_SECONDS"
  done
}

if [[ "${1:-}" == "--install" ]]; then
  install_deps
  exit 0
fi

main_loop
