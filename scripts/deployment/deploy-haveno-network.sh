#!/usr/bin/env bash
#
# Deploy a self-hosted Haveno network on Monero mainnet.
#
# This script automates the buildable, headless parts of the deployment:
#   - installs Java 21 and build tools
#   - clones your customized fork
#   - patches your network public key (optional)
#   - builds with `make skip-tests`
#   - runs the Monero node, two seednodes, and the arbitrator daemon as systemd services
#
# The interactive GUI steps (register the arbitrator with ctrl+r, add the network
# filter with ctrl+f) cannot be automated; this script prints reminders for them.
#
# Usage:
#   export REPO_URL=https://github.com/<you>/<your-fork>.git
#   export API_PASSWORD=<strong-secret-without-spaces>
#   ./scripts/deployment/deploy-haveno-network.sh install
#   ./scripts/deployment/deploy-haveno-network.sh keypairs
#   ./scripts/deployment/deploy-haveno-network.sh monerod
#   ./scripts/deployment/deploy-haveno-network.sh seednodes
#   ./scripts/deployment/deploy-haveno-network.sh arbitrator
#   ./scripts/deployment/deploy-haveno-network.sh status
#
# Optional env vars:
#   PUBLIC_KEY   - your generated network public key (hex); auto-patched into DevEnv.java
#   HAVENO_HOME  - install directory (default: ~/haveno)
#
set -euo pipefail

HAVENO_HOME="${HAVENO_HOME:-$HOME/haveno}"
REPO_URL="${REPO_URL:-}"
PUBLIC_KEY="${PUBLIC_KEY:-}"
API_PASSWORD="${API_PASSWORD:-}"
RUN_USER="$(id -un)"
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi

say()  { echo ""; echo "==> $*"; }
warn() { echo "==> WARN: $*" >&2; }
die()  { echo "==> ERROR: $*" >&2; exit 1; }

usage() {
  sed -n '2,28p' "$0"
}

# SDKMAN-managed Java is only on PATH inside login shells; re-source it if present.
if [ -s "$HOME/.sdkman/bin/sdkman-init.sh" ]; then
  # shellcheck disable=SC1091
  source "$HOME/.sdkman/bin/sdkman-init.sh"
fi

require_repo_url() {
  [ -n "$REPO_URL" ] || die "Set REPO_URL to your fork URL, e.g.: export REPO_URL=https://github.com/you/haveno.git"
}

install_deps() {
  say "Installing base packages"
  $SUDO apt-get update -y
  $SUDO apt-get install -y make wget git tmux curl
  if java -version 2>&1 | grep -q 'version "21'; then
    say "Java 21 already installed"
  elif $SUDO apt-get install -y openjdk-21-jdk 2>/dev/null; then
    say "Installed openjdk-21-jdk via apt"
  else
    say "Installing Java 21 via SDKMAN"
    curl -s "https://get.sdkman.io" | bash
    # shellcheck disable=SC1091
    source "$HOME/.sdkman/bin/sdkman-init.sh"
    sdk install java 21.0.9.fx-librca
  fi
  java -version
}

clone_and_build() {
  require_repo_url
  install_deps
  if [ -d "$HAVENO_HOME/.git" ]; then
    say "Updating existing checkout: $HAVENO_HOME"
    git -C "$HAVENO_HOME" pull --ff-only || warn "git pull failed, continuing with existing checkout"
  else
    say "Cloning $REPO_URL -> $HAVENO_HOME"
    git clone "$REPO_URL" "$HAVENO_HOME"
  fi
  cd "$HAVENO_HOME"
  git checkout master 2>/dev/null || warn "no 'master' branch; staying on the default branch"

  if [ -n "$PUBLIC_KEY" ]; then
    say "Patching NETWORK_PUBLIC_KEY in DevEnv.java"
    sed -i "s/PASTE_PUBLIC_KEY_HEX_HERE/$PUBLIC_KEY/" common/src/main/java/haveno/common/app/DevEnv.java
  else
    warn "PUBLIC_KEY not set. The build will succeed, but the network will not work until you paste"
    warn "your generated public key into common/src/main/java/haveno/common/app/DevEnv.java"
    warn "(constant NETWORK_PUBLIC_KEY). Generate a keypair with: ./gradlew :core:generateKeypairs"
  fi

  say "Building with make skip-tests (this can take a long time)"
  make skip-tests

  [ -x "$HAVENO_HOME/.localnet/monerod" ] || die "monerod binary missing after build; run: ./gradlew :core:havenoDeps"
  [ -x "$HAVENO_HOME/haveno-seednode" ] || die "haveno-seednode launcher missing after build"
}

generate_keypairs() {
  [ -d "$HAVENO_HOME" ] || die "run 'install' first"
  cd "$HAVENO_HOME"
  say "Generating keypairs (public/private)"
  ./gradlew :core:generateKeypairs
  echo ""
  say "Copy the first public key, then re-run:"
  echo "  PUBLIC_KEY=<public-key> REPO_URL=$REPO_URL $0 install"
}

write_monerod_unit() {
  say "Installing monerod systemd service"
  $SUDO tee /etc/systemd/system/haveno-monerod.service >/dev/null <<UNIT
[Unit]
Description=Haveno private Monero node (mainnet)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$HAVENO_HOME
ExecStart=$HAVENO_HOME/.localnet/monerod --bootstrap-daemon-address auto --rpc-access-control-origins http://localhost:8080 --rpc-max-connections 1000 --max-connections-per-ip 10 --rpc-max-connections-per-private-ip 1000
Restart=always
RestartSec=10
LimitNOFILE=16384

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now haveno-monerod.service
  say "Monero node started. Sync the full chain before starting seednodes/arbitrator (this takes days)."
  say "Watch progress: journalctl -u haveno-monerod -f"
}

write_seednode_unit() {
  local name="$1" port="$2" appname="$3"
  $SUDO tee "/etc/systemd/system/${name}.service" >/dev/null <<UNIT
[Unit]
Description=Haveno seednode ${name}
After=network-online.target haveno-monerod.service
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$HAVENO_HOME
ExecStart=$HAVENO_HOME/haveno-seednode --baseCurrencyNetwork=XMR_MAINNET --useLocalhostForP2P=false --useDevPrivilegeKeys=false --hiddenServiceParams=PoWDefensesEnabled=1,PoWQueueRate=50,PoWQueueBurst=250 --nodePort=${port} --appName=${appname} --xmrNode=http://127.0.0.1:18081
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
}

start_seednodes() {
  write_seednode_unit haveno-seednode 1002 haveno-XMR_MAINNET_Seed_1002
  write_seednode_unit haveno-seednode2 1003 haveno-XMR_MAINNET_Seed_1003
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now haveno-seednode.service haveno-seednode2.service
  say "Waiting 60s for the Tor hidden services to start..."
  sleep 60
  echo ""
  say "Seednode onion addresses (also: journalctl -u haveno-seednode -b -f):"
  for svc in haveno-seednode haveno-seednode2; do
    local addr
    addr="$($SUDO journalctl -u "$svc" -b --no-pager 2>/dev/null | grep -oE '[a-z0-9]{56}[.]onion' | tail -1 || true)"
    if [ -n "$addr" ]; then
      echo "  $svc -> $addr"
    else
      warn "could not auto-detect onion address for $svc yet; check journalctl"
    fi
  done
  echo ""
  say "Record the addresses in core/src/main/resources/xmr_mainnet.seednodes, e.g.:"
  echo "  <seednode1>.onion:1002 (@seednode1)"
  echo "  <seednode2>.onion:1003 (@seednode2)"
  say "Then rebuild and restart the seednodes so the change takes effect:"
  echo "  cd $HAVENO_HOME && make skip-tests"
  echo "  $SUDO systemctl restart haveno-seednode haveno-seednode2"
}

write_arbitrator_unit() {
  [ -n "$API_PASSWORD" ] || die "Set API_PASSWORD (no spaces) before starting the arbitrator"
  say "Installing arbitrator daemon systemd service"
  $SUDO tee /etc/systemd/system/haveno-arbitrator.service >/dev/null <<UNIT
[Unit]
Description=Haveno arbitrator daemon (mainnet)
After=network-online.target haveno-monerod.service
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$HAVENO_HOME
ExecStart=$HAVENO_HOME/haveno-daemon --baseCurrencyNetwork=XMR_MAINNET --useLocalhostForP2P=false --useDevPrivilegeKeys=false --nodePort=9999 --appName=haveno-XMR_MAINNET_arbitrator --apiPassword=$API_PASSWORD --apiPort=1200 --passwordRequired=false --xmrNode=http://127.0.0.1:18081 --useNativeXmrWallet=false
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
UNIT
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now haveno-arbitrator.service
  echo ""
  say "Arbitrator daemon is running. Still required from the desktop GUI:"
  echo "  1. Run 'make arbitrator-desktop-mainnet' (on a machine with a display, or via VNC/X11)."
  echo "  2. Account tab -> press ctrl+r -> enter your private key to register the arbitrator."
  echo "  3. Press ctrl+f -> enter the developer private key -> 'Add Filter' to register the network filter."
}

status() {
  $SUDO systemctl --no-pager --lines=0 status haveno-monerod haveno-seednode haveno-seednode2 haveno-arbitrator 2>/dev/null || true
  echo ""
  if command -v curl >/dev/null 2>&1; then
    curl -s http://127.0.0.1:18081/get_info | grep -E '"height"|"status"|"synchronized"' || true
  fi
}

case "${1:-help}" in
  install)    clone_and_build ;;
  keypairs)   generate_keypairs ;;
  monerod)    write_monerod_unit ;;
  seednodes)  start_seednodes ;;
  arbitrator) write_arbitrator_unit ;;
  status)     status ;;
  *)          usage ;;
esac