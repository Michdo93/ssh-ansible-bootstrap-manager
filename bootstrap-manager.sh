#!/usr/bin/env bash
# SSH Ansible Bootstrap Manager - run on the Ansible control node.
#
# Creates a dedicated Ansible account on Linux, Kali and Windows hosts, installs
# the control node's SSH public key for it (generating a key pair if needed) and
# configures privilege escalation:
#   sudo-mode vault     (default) "<user> ALL=(ALL:ALL) ALL"; Ansible supplies the
#                       password from an Ansible Vault (see ansible-inventory-generator)
#   sudo-mode nopasswd  "<user> ALL=(ALL:ALL) NOPASSWD: ALL"
#
# Usage:
#   ./bootstrap-manager.sh                       interactive: scan a range, bootstrap hosts
#   ./bootstrap-manager.sh --host 192.168.0.20 --admin-user pi --user ansible [--port 22]
#                          [--sudo-mode vault|nopasswd] [--key ~/.ssh/id_ed25519]
# Passwords are prompted; for automation set BOOTSTRAP_ADMIN_PASSWORD (empty = use
# key/agent for the admin login) and BOOTSTRAP_ACCOUNT_PASSWORD.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/bootstrap-lib.sh
source "$SCRIPT_DIR/lib/bootstrap-lib.sh"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

host='' port=22 admin_user='' account_user='' sudo_mode=vault
while (($#)); do
  case $1 in
    --host) host=${2:-}; shift 2 ;;
    --port) port=${2:-}; shift 2 ;;
    --admin-user) admin_user=${2:-}; shift 2 ;;
    --user) account_user=${2:-}; shift 2 ;;
    --sudo-mode) sudo_mode=${2:-}; shift 2 ;;
    --key) export BM_KEY_FILE=${2:-}; shift 2 ;;
    -h|--help) usage 0 ;;
    *) bm_err "Unknown argument: $1"; usage 2 ;;
  esac
done
[[ $sudo_mode == vault || $sudo_mode == nopasswd ]] || { bm_err '--sudo-mode must be vault or nopasswd.'; exit 2; }
bm_valid_port "$port" || { bm_err "Invalid port: $port"; exit 2; }

bm_check_dependencies || exit 1
bm_ensure_keypair || exit 1

ask_account() {
  if [[ -z $account_user ]]; then
    read -r -p 'Name of the dedicated Ansible account [ansible]: ' account_user || exit 0
    account_user=${account_user:-ansible}
  fi
  bm_valid_unix_user "$account_user" || { bm_err "Invalid account name '$account_user' (lowercase, digits, _ and -)."; exit 2; }
  if [[ -n ${BOOTSTRAP_ACCOUNT_PASSWORD+x} ]]; then
    account_password=$BOOTSTRAP_ACCOUNT_PASSWORD
  else
    until bm_read_secret_confirmed "Password for '$account_user' (used for sudo/runas, stored only in Ansible Vault)"; do :; done
    account_password=$BM_SECRET; BM_SECRET=''
  fi
  [[ -n $account_password && $account_password != *$'\n'* ]] || { bm_err 'Invalid account password.'; exit 2; }
}

ask_admin() { # IP
  local prompt_default=${last_admin_user:-}
  if [[ -n $admin_user && -z ${interactive_scan:-} ]]; then :
  else
    read -r -p "Administrator SSH login for $1${prompt_default:+ [$prompt_default]}: " admin_user || return 1
    admin_user=${admin_user:-$prompt_default}
  fi
  [[ -n $admin_user ]] || { printf 'Skipped: no administrator login given.\n'; return 1; }
  if [[ -n ${BOOTSTRAP_ADMIN_PASSWORD+x} ]]; then admin_password=$BOOTSTRAP_ADMIN_PASSWORD
  else
    read -r -s -p "Password for $admin_user@$1 (empty = SSH key/agent): " admin_password || return 1; printf '\n'
  fi
  last_admin_user=$admin_user
}

bootstrap_one() { # IP PORT
  local tries rc
  for tries in 1 2 3; do
    ask_admin "$1" || return 1
    bm_bootstrap_host "$1" "$2" "$admin_user" "$admin_password" "$account_user" "$account_password" "$sudo_mode"; rc=$?
    admin_password=
    ((rc == 2)) && bm_is_interactive && [[ -z ${BOOTSTRAP_ADMIN_PASSWORD+x} ]] && ((tries < 3)) && { printf 'Try again (%d of 3).\n' "$((tries + 1))"; continue; }
    break
  done
  if ((rc == 0)); then
    printf 'Done: %s is ready for Ansible as %s (%s, key %s).\n' "$1" "$account_user" "$BM_OS_FAMILY" "$BM_KEY"
    [[ $BM_OS_FAMILY == windows || $sudo_mode == vault ]] && printf 'Privilege escalation needs the account password -> store it with ansible-inventory-generator (Ansible Vault).\n'
  fi
  return "$rc"
}

if [[ -n $host ]]; then
  bm_ipv4_to_int "$host" >/dev/null || { bm_err "Invalid IPv4 address: $host"; exit 2; }
  ask_account
  bootstrap_one "$host" "$port"; exit $?
fi

# ------------------------------------------------------- interactive mode ---
interactive_scan=1
ask_account
if bm_ask_yes_no 'Use passwordless sudo (NOPASSWD) on Linux instead of Vault-protected sudo?' n; then sudo_mode=nopasswd; fi
while true; do
  read -r -p 'First IPv4 address: ' first || exit 0
  read -r -p 'Last IPv4 address:  ' last || exit 0
  first_n=$(bm_ipv4_to_int "$first") || { printf 'Invalid first IPv4 address.\n'; continue; }
  last_n=$(bm_ipv4_to_int "$last") || { printf 'Invalid last IPv4 address.\n'; continue; }
  ((first_n <= last_n)) || { printf 'The first address must not be greater than the last address.\n'; continue; }
  ((last_n - first_n <= 65535)) || { printf 'Ranges are limited to 65,536 addresses.\n'; continue; }
  read -r -p "SSH port(s), comma-separated [$port]: " port_input || exit 0
  IFS=', ' read -ra ports <<< "${port_input:-$port}"
  ok=true; for p in "${ports[@]}"; do bm_valid_port "$p" || ok=false; done
  [[ $ok == true && ${#ports[@]} -gt 0 ]] || { printf 'Invalid port list.\n'; continue; }
  bm_ask_yes_no "Scan $first through $last?" y && break
done

bm_scan "$first" "$last" "${ports[@]}"
((${#BM_SCAN_RESULTS[@]})) || { printf 'No SSH-reachable devices found.\n'; exit 0; }
declare -a done_hosts=() failed_hosts=()
for entry in "${BM_SCAN_RESULTS[@]}"; do
  ip=${entry%%|*}; IFS=, read -ra open <<< "${entry#*|}"
  printf '\nDevice: %s (port %s)\n' "$ip" "${open[0]}"
  if bm_key_exec "$ip" "${open[0]}" "$account_user" exit >/dev/null 2>&1; then
    printf '%s already accepts the key for %s.\n' "$ip" "$account_user"
    bm_ask_yes_no 'Run the bootstrap anyway (updates password/sudo rule)?' n || { done_hosts+=("$ip"); continue; }
  else
    bm_ask_yes_no 'Run the Ansible bootstrap on this device?' y || { printf 'Skipped %s.\n' "$ip"; continue; }
  fi
  if bootstrap_one "$ip" "${open[0]}"; then done_hosts+=("$ip"); else failed_hosts+=("$ip"); fi
done
account_password=
printf '\nFinished. Ready: %s\n' "${done_hosts[*]:-none}"
((${#failed_hosts[@]})) && printf 'Failed:  %s\n' "${failed_hosts[*]}"
printf 'Next step: run ansible-inventory-generator to write the inventory and Ansible Vault.\n'
