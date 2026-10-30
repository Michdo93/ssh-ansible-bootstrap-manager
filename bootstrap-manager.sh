#!/usr/bin/env bash
# Interactive SSH dispatcher for configurable OS-specific Ansible bootstrap scripts.
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROVIDERS_FILE="$SCRIPT_DIR/providers.sh"
[[ -r "$PROVIDERS_FILE" ]] || { printf 'Missing provider configuration: %s\n' "$PROVIDERS_FILE" >&2; exit 1; }
# providers.sh is executable configuration. Only load files from a trusted local checkout.
# shellcheck source=providers.sh
source "$PROVIDERS_FILE"

readonly SSH_PORT=22
readonly CONNECT_TIMEOUT=5

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
ask_yes_no() {
  local prompt=$1 default=$2 answer
  while true; do
    if [[ $default == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case "$answer" in y|yes) return 0;; n|no) return 1;; '') [[ $default == y ]] && return 0 || return 1;; *) printf 'Please answer y/yes or n/no.\n';; esac
  done
}
ipv4_to_int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  [[ "$a$b$c$d" =~ ^[0-9]+$ ]] || return 1
  ((a<=255 && b<=255 && c<=255 && d<=255)) || return 1
  printf '%u' "$(((a<<24)|(b<<16)|(c<<8)|d))"
}
int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n>>24&255))" "$((n>>16&255))" "$((n>>8&255))" "$((n&255))"; }
ssh_base=(ssh -p "$SSH_PORT" -o ConnectTimeout="$CONNECT_TIMEOUT" -o NumberOfPasswordPrompts=1 -o PreferredAuthentications=publickey,password,keyboard-interactive -o StrictHostKeyChecking=accept-new)

command -v ssh >/dev/null || die 'OpenSSH client (ssh) is required.'
command -v timeout >/dev/null || die "The 'timeout' command is required (Linux or WSL)."
[[ ${#BOOTSTRAP_PROVIDERS[@]} -gt 0 ]] || die 'No providers are configured in providers.sh.'

while true; do
  read -r -p 'First IPv4 address: ' first || exit 0
  read -r -p 'Last IPv4 address:  ' last || exit 0
  first_n=$(ipv4_to_int "$first") || { printf 'Invalid first IPv4 address.\n'; continue; }
  last_n=$(ipv4_to_int "$last") || { printf 'Invalid last IPv4 address.\n'; continue; }
  (( first_n <= last_n )) || { printf 'The first address must not be greater than the last address.\n'; continue; }
  (( last_n-first_n <= 65535 )) || { printf 'Ranges are limited to 65,536 addresses.\n'; continue; }
  ask_yes_no "Scan ${first} through ${last}?" y && break
done

printf '\nScanning SSH on TCP port %d...\n' "$SSH_PORT"
declare -a hosts=()
for ((n=first_n; n<=last_n; n++)); do
  ip=$(int_to_ipv4 "$n")
  probe=$(timeout "$CONNECT_TIMEOUT" "${ssh_base[@]}" -F /dev/null -o BatchMode=yes "bootstrap-probe@$ip" true 2>&1 || true)
  if [[ $probe == *'Permission denied'* || $probe == *'Too many authentication failures'* || $probe == *'no mutual signature'* ]]; then hosts+=("$ip"); fi
done
if ((${#hosts[@]}==0)); then printf 'No SSH-reachable devices found.\n'; exit 0; fi
printf 'Found %d SSH-reachable device(s).\n' "${#hosts[@]}"

for ip in "${hosts[@]}"; do
  printf '\nDevice: %s\n' "$ip"
  ask_yes_no 'Run the configured Ansible bootstrap on this device?' y || { printf 'Skipped %s.\n' "$ip"; continue; }
  read -r -p 'SSH username: ' ssh_user
  [[ -n $ssh_user ]] || { printf 'Skipped: SSH username is empty.\n'; continue; }
  read -r -p 'New Ansible account username: ' new_user
  [[ $new_user =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] || { printf 'Invalid account name; use a Unix-style username.\n'; continue; }
  read -r -s -p 'New Ansible account password: ' new_password; printf '\n'
  [[ -n $new_password ]] || { printf 'Skipped: password cannot be empty.\n'; unset new_password; continue; }
  read -r -s -p 'Confirm password: ' password_confirm; printf '\n'
  if [[ $new_password != "$password_confirm" ]]; then printf 'Passwords do not match; skipped %s.\n' "$ip"; unset new_password password_confirm; continue; fi
  unset password_confirm

  os_id= os_name= os_version=
  authenticated=false
  # uname succeeds on supported POSIX targets and avoids exposing OS details in the UI.
  # A Windows OpenSSH server normally uses PowerShell as its default shell, so its
  # detection is attempted if the POSIX probe does not return a Linux marker.
  for attempt in 1 2 3; do
    printf 'SSH login attempt %d of 3 for %s.\n' "$attempt" "$ip"
    linux_info=$(timeout 30 "${ssh_base[@]}" "$ssh_user@$ip" 'sh -c "cat /etc/os-release 2>/dev/null; uname -s 2>/dev/null"' 2>&1 || true)
    if [[ $linux_info == *'ID='* && $linux_info == *'Linux'* ]]; then
      authenticated=true
      os_id=$(printf '%s\n' "$linux_info" | sed -n 's/^ID=//p' | head -n1 | tr -d '"')
      os_name=$(printf '%s\n' "$linux_info" | sed -n 's/^PRETTY_NAME=//p' | head -n1 | tr -d '"')
      break
    fi
    win_command="powershell.exe -NoProfile -NonInteractive -Command \"[Console]::WriteLine('BOOTSTRAP_WINDOWS;' + [Environment]::OSVersion.VersionString)\""
    win_info=$(timeout 30 "${ssh_base[@]}" "$ssh_user@$ip" "$win_command" 2>&1 || true)
    if [[ $win_info == *BOOTSTRAP_WINDOWS* ]]; then authenticated=true; os_id=windows; os_name='Windows'; os_version=${win_info#*BOOTSTRAP_WINDOWS\;}; break; fi
    if [[ $linux_info == *'Permission denied'* || $win_info == *'Permission denied'* || $linux_info == *'Connection timed out'* ]]; then
      ((attempt < 3)) && printf 'SSH login failed.\n' || printf 'SSH login failed after 3 attempts; moving to the next device.\n'
    else
      printf 'Could not identify a supported operating system on %s.\n' "$ip"
      break
    fi
  done
  if [[ $authenticated != true ]]; then unset new_password; continue; fi
  [[ -n $os_id ]] || { printf 'Could not identify the operating system.\n'; unset new_password; continue; }
  printf 'Detected supported platform: %s\n' "${os_name:-Windows}"

  provider_id=
  for provider in "${BOOTSTRAP_PROVIDERS[@]}"; do
    IFS='|' read -r id pattern kind url <<< "$provider"
    if [[ $os_id =~ $pattern ]]; then provider_id=$id; provider_kind=$kind; provider_url=$url; break; fi
  done
  if [[ -z $provider_id ]]; then printf 'No bootstrap provider is configured for this operating system; skipped.\n'; unset new_password; continue; fi
  printf 'Selected provider: %s\n' "$provider_id"
  if ! ask_yes_no 'Download and execute this provider bootstrap?' y; then printf 'Skipped %s.\n' "$ip"; unset new_password; continue; fi

  # Prevent breaking out of each target shell's single-quoted string. Values are never
  # echoed. Note: the upstream scripts receive a password argument (visible to privileged
  # process inspection on the target while running), as required by their current interface.
  shell_quote() { local v=$1; v=${v//\'/\'\\\'\'}; printf "'%s'" "$v"; }
  q_user=$(shell_quote "$new_user")
  q_pass=$(shell_quote "$new_password")
  q_url=$(shell_quote "$provider_url")

  if [[ $provider_kind == powershell ]]; then
    # Windows OpenSSH must be configured with PowerShell as its default shell.
    remote="& ([scriptblock]::Create((irm $q_url))) -Username $q_user -Password $q_pass"
    output=$(timeout 900 "${ssh_base[@]}" -tt "$ssh_user@$ip" "$remote" 2>&1); rc=$?
  elif [[ $provider_kind == shell ]]; then
    # Provider script is fetched and piped directly to bash; curl is installed if absent.
    remote="if ! command -v curl >/dev/null 2>&1; then if [ \"\$(id -u)\" -eq 0 ]; then if command -v apt-get >/dev/null 2>&1; then apt-get update && apt-get install -y curl; elif command -v dnf >/dev/null 2>&1; then dnf install -y curl; elif command -v yum >/dev/null 2>&1; then yum install -y curl; elif command -v pacman >/dev/null 2>&1; then pacman -Sy --noconfirm curl; elif command -v zypper >/dev/null 2>&1; then zypper --non-interactive install curl; else echo 'No supported package manager found for curl.' >&2; exit 30; fi; elif command -v sudo >/dev/null 2>&1; then if command -v apt-get >/dev/null 2>&1; then sudo apt-get update && sudo apt-get install -y curl; elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y curl; elif command -v yum >/dev/null 2>&1; then sudo yum install -y curl; elif command -v pacman >/dev/null 2>&1; then sudo pacman -Sy --noconfirm curl; elif command -v zypper >/dev/null 2>&1; then sudo zypper --non-interactive install curl; else echo 'No supported package manager found for curl.' >&2; exit 30; fi; else echo 'Cannot install curl without administrator access.' >&2; exit 31; fi; fi && curl -fsSL $q_url | sudo bash -s -- username=$q_user password=$q_pass"
    output=$(timeout 900 "${ssh_base[@]}" -tt "$ssh_user@$ip" "$remote" 2>&1); rc=$?
  else
    printf 'Provider %s has unknown execution type; skipped.\n' "$provider_id"; unset new_password; continue
  fi
  if [[ -n $new_password ]]; then output=${output//"$new_password"/[redacted]}; fi
  unset new_password
  if ((rc == 0)); then printf 'Bootstrap completed successfully on %s.\n' "$ip"
  else
    printf 'Bootstrap failed on %s (exit %d).\n' "$ip" "$rc"
    # Display provider output for actionable diagnostics, while never reprinting secrets.
    printf '%s\n' "$output" | sed -E "s/${new_user//\//\\/}/<account>/g" | tail -n 30
  fi
done
printf '\nFinished.\n'
