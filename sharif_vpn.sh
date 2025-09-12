#!/usr/bin/env bash

set -Eeuo pipefail

CONN_NAME="${CONN_NAME:-}"                  # auto-detected if empty
L2TP_PEER="${L2TP_PEER:-sharif}"
REMOTE_HOST="${REMOTE_HOST:-access2.sharif.edu}"
ROUTE_CIDR="${ROUTE_CIDR:-172.27.48.0/22}"

# Services (on Arch)
SWAN_STARTER="strongswan-starter.service"   # stroke backend (ipsec commands)
SWAN_SYSTEMD="strongswan.service"           # charon-systemd (swanctl backend)
XL2TPD="xl2tpd.service"

log(){ printf '[%s] %s\n' "$(date +'%F %T')" "$*" >&2; }
die(){ echo "ERROR: $*" >&2; exit 1; }

need_sudo(){ sudo -n true 2>/dev/null || { echo "This needs sudo."; sudo -v; }; }

stop_daemons(){
  log "Stopping IKE daemons so UDP 500/4500 are free…"
  sudo systemctl stop "$SWAN_SYSTEMD" 2>/dev/null || true
  sudo systemctl stop "$SWAN_STARTER" 2>/dev/null || true
  pkill -u root -x charon 2>/dev/null || true
  sleep 0.4
}

free_ports_check(){
  if sudo ss -lunp | grep -E ':(500|4500)\s' >/dev/null; then
    log "Warning: UDP 500/4500 still in use:"
    sudo ss -lunp | grep -E ':(500|4500)\s' || true
  else
    log "UDP 500/4500 are free."
  fi
}

start_starter_stack(){
  log "Starting $SWAN_STARTER and $XL2TPD…"
  sudo systemctl start "$SWAN_STARTER"
  sudo systemctl start "$XL2TPD"
  sleep 0.7
}

resolve_remote(){
  log "Resolving $REMOTE_HOST…"
  for _ in {1..10}; do getent hosts "$REMOTE_HOST" >/dev/null && return 0; sleep 0.5; done
  die "cannot resolve $REMOTE_HOST"
}

detect_conn_name(){
  [[ -n "$CONN_NAME" ]] && return 0
  local files=()
  [[ -f /etc/ipsec.conf ]] && files+=("/etc/ipsec.conf")
  [[ -f /etc/strongswan/ipsec.conf ]] && files+=("/etc/strongswan/ipsec.conf")
  [[ ${#files[@]} -eq 0 ]] && die "No ipsec.conf found (checked /etc/ipsec.conf and /etc/strongswan/ipsec.conf)"

  local name
  name="$(grep -hE '^[[:space:]]*conn[[:space:]]+' "${files[@]}" \
          | awk '{print $2}' \
          | grep -E 'sharif' || true)"
  if [[ -z "$name" ]]; then
    name="$(grep -hE '^[[:space:]]*conn[[:space:]]+' "${files[@]}" \
            | awk '{print $2}' \
            | grep -vE '^(%default|default)$' \
            | head -n1)"
  fi
  [[ -n "$name" ]] || die "Could not auto-detect a conn name in ipsec.conf"
  CONN_NAME="$name"
  log "Auto-detected CONN_NAME='${CONN_NAME}'"
}

ipsec_reload(){
  log "Reloading ipsec config & secrets…"
  sudo ipsec reload >/dev/null || true
  sudo ipsec rereadsecrets >/dev/null || true
}

conn_loaded(){
  sudo ipsec statusall 2>/dev/null | grep -Fq " $CONN_NAME"
}

ipsec_up(){
  detect_conn_name
  ipsec_reload
  for _ in {1..8}; do conn_loaded && break; sleep 0.5; done
  conn_loaded || log "Conn not visible yet; proceeding with ipsec up and retries…"

  log "Bringing up ${CONN_NAME}…"
  for _ in {1..8}; do
    if sudo ipsec up "$CONN_NAME"; then return 0; fi
    sleep 1
  done
  die "ipsec up $CONN_NAME failed (check /etc/ipsec.conf name and syntax)"
}

find_xl2tp_ctrl(){
  # Return path of control socket if present; empty if not
  local c
  for c in /var/run/xl2tpd/l2tp-control /run/xl2tpd/l2tp-control; do
    [[ -S "$c" ]] && { echo "$c"; return; }
  done
  echo ""
}

dial_xl2tp_via_ctrl(){
  local ctrl="$1"
  log "Dialing L2TP peer ${L2TP_PEER} via ${ctrl}…"
  echo "c ${L2TP_PEER}" | sudo tee "$ctrl" >/dev/null
}

dial_xl2tp_fallback_autodial(){
  # Use xl2tpd's autodial (requires 'autodial = yes' in [lac])
  log "Control socket not found; trying xl2tpd autodial (restart)…"
  sudo systemctl restart "$XL2TPD"
}

wait_ppp(){
  # Echo the interface name only
  local ifc
  for _ in {1..40}; do
    ifc="$(ip -o link show | awk -F': ' '/ppp[0-9]+/{print $2; exit}')"
    [[ -n "$ifc" ]] && { echo "$ifc"; return; }
    sleep 0.5
  done
  return 1
}

wait_ppp_ready(){
  # Wait until PPP IF is UP and has an IPv4 address
  local ifc="$1"
  for _ in {1..40}; do
    # flags contain UP when interface is administratively up
    if ip -o link show dev "$ifc" | awk -F'[<>]' '{print $2}' | grep -Fq "UP"; then
      if ip -4 addr show dev "$ifc" | grep -Fq "inet "; then
        return 0
      fi
    fi
    sleep 0.5
  done
  # As a last attempt, try to bring it up and re-check quickly
  sudo ip link set "$ifc" up || true
  sleep 0.5
  ip -4 addr show dev "$ifc" | grep -Fq "inet "
}

add_route(){
  local ifc="$1"
  if ip route show "$ROUTE_CIDR" | grep -Fq -- "$ifc"; then
    log "Route $ROUTE_CIDR already via $ifc"
    return 0
  fi
  # Try up to 3 times in case the link is just becoming ready
  for _ in 1 2 3; do
    if sudo ip route add "$ROUTE_CIDR" dev "$ifc" 2>/dev/null; then
      log "Added route $ROUTE_CIDR via $ifc"
      return 0
    fi
    sleep 0.7
  done
  die "Failed to add route $ROUTE_CIDR via $ifc (device may not be fully up)"
}

remove_route(){
  local ifc="$1"
  if ip route show "$ROUTE_CIDR" | grep -Fq -- "$ifc"; then
    log "Removing route $ROUTE_CIDR from $ifc…"
    sudo ip route del "$ROUTE_CIDR" dev "$ifc" 2>/dev/null || true
  fi
}

cmd_up(){
  need_sudo
  stop_daemons
  free_ports_check
  start_starter_stack
  resolve_remote
  ipsec_up

  # Prefer control socket if available; otherwise use autodial
  local ctrl; ctrl="$(find_xl2tp_ctrl)"
  if [[ -n "$ctrl" ]]; then
    dial_xl2tp_via_ctrl "$ctrl"
  else
    dial_xl2tp_fallback_autodial
  fi

  log "Waiting for PPP interface…"
  local ppp
  if ! ppp="$(wait_ppp)"; then
    die "PPP interface did not appear"
  fi
  log "PPP detected on ${ppp}; waiting until it is ready…"
  if ! wait_ppp_ready "$ppp"; then
    die "PPP interface $ppp did not become ready (UP + IPv4 address)"
  fi
  log "PPP $ppp is ready"
  sudo ip l2tp show session || true
  add_route "$ppp"
  log "UP complete."
}

cmd_down(){
  need_sudo
  # Remove route (if we know the PPP IF)
  local ppp; ppp="$(ip -o link show | awk -F': ' '/ppp[0-9]+/{print $2}')" || true
  [[ -n "$ppp" ]] && remove_route "$ppp"

  # Try to hang up via control; if unavailable, stop xl2tpd
  local ctrl; ctrl="$(find_xl2tp_ctrl)"
  if [[ -n "$ctrl" ]]; then
    log "Hanging up L2TP peer ${L2TP_PEER}…"
    echo "d ${L2TP_PEER}" | sudo tee "$ctrl" >/dev/null || true
  else
    log "L2TP control socket not present; stopping xl2tpd…"
    sudo systemctl stop "$XL2TPD" 2>/dev/null || true
  fi

  # Bring IPsec down & stop services so ports are free
  detect_conn_name || true
  if [[ -n "${CONN_NAME:-}" ]]; then
    log "Bringing down IPsec connection ${CONN_NAME}…"
    sudo ipsec down "$CONN_NAME" 2>/dev/null || true
  else
    log "Conn name not known; skipping ipsec down."
  fi

  log "Stopping services ($SWAN_STARTER, $SWAN_SYSTEMD, $XL2TPD)…"
  sudo systemctl stop "$XL2TPD" 2>/dev/null || true
  sudo systemctl stop "$SWAN_STARTER" 2>/dev/null || true
  sudo systemctl stop "$SWAN_SYSTEMD" 2>/dev/null || true
  pkill -u root -x charon 2>/dev/null || true
  free_ports_check
  log "DOWN complete."
}

usage(){
  cat <<EOF
Usage:
  $0 up     # stop anything on UDP 500/4500, start strongswan-starter + xl2tpd, bring tunnel up
  $0 down   # hang up L2TP (via control or autodial fallback), bring IPsec down, stop services

Env overrides:
  CONN_NAME   (auto-detected if empty)
  L2TP_PEER   (default: ${L2TP_PEER})
  REMOTE_HOST (default: ${REMOTE_HOST})
  ROUTE_CIDR  (default: ${ROUTE_CIDR})
EOF
}

case "${1:-}" in
  up)   cmd_up ;;
  down) cmd_down ;;
  *)    usage; exit 2 ;;
esac

