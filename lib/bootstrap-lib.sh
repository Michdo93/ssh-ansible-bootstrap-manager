#!/usr/bin/env bash
# Shared library for the SSH Ansible Bootstrap Manager.
#
# Sourced by bootstrap-manager.sh and by ansible-inventory-generator. Runs on the
# Ansible control node. It
#   * ensures that an SSH key pair exists (generates ed25519 if none is found),
#   * scans IPv4 ranges for open SSH ports,
#   * logs in with an administrative account (password or key), detects the OS,
#   * uploads the matching provider bootstrap script and runs it with the
#     account name, its password (via stdin/temporary file, never via argv) and
#     the control node's public key,
#   * verifies key-based login and privilege escalation for the new account.
#
# Host keys: first contact is accepted automatically (StrictHostKeyChecking=
# accept-new, the scripted equivalent of answering "yes"). A *changed* host key
# is never accepted silently; interactive callers are asked whether the stale
# known_hosts entry should be removed (typical after reinstalling a VM).
#
# shellcheck disable=SC2034  # result variables are consumed by callers

[[ -n ${BM_LIB_LOADED:-} ]] && return 0
BM_LIB_LOADED=1

BM_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
BM_ROOT_DIR=$(cd -- "$BM_LIB_DIR/.." && pwd)
BM_CONNECT_TIMEOUT=${BM_CONNECT_TIMEOUT:-5}
BM_BOOTSTRAP_TIMEOUT=${BM_BOOTSTRAP_TIMEOUT:-1800}
BM_INTERACTIVE=${BM_INTERACTIVE:-auto}
BM_KNOWN_HOSTS=${BM_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}

# shellcheck source=../providers.sh
source "$BM_ROOT_DIR/providers.sh"

# ---------------------------------------------------------------- helpers ---
bm_info() { printf '%s\n' "$*"; }
bm_warn() { printf 'Warning: %s\n' "$*" >&2; }
bm_err()  { printf 'Error: %s\n' "$*" >&2; }

bm_is_interactive() {
  case $BM_INTERACTIVE in
    yes|true|1) return 0 ;;
    no|false|0) return 1 ;;
    *) [[ -t 0 ]] ;;
  esac
}

bm_ask_yes_no() {
  local prompt=$1 default=${2:-n} answer
  while true; do
    if [[ $default == y ]]; then read -r -p "$prompt [Y/n] " answer || return 1
    else read -r -p "$prompt [y/N] " answer || return 1; fi
    answer=${answer,,}
    case $answer in
      y|yes|j|ja) return 0 ;;
      n|no|nein) return 1 ;;
      '') [[ $default == y ]] && return 0 || return 1 ;;
      *) printf 'Please answer y/yes or n/no.\n' ;;
    esac
  done
}

# Read a secret twice; result in BM_SECRET. Returns 1 on mismatch/empty/newline.
bm_read_secret_confirmed() {
  local prompt=$1 confirm
  read -r -s -p "$prompt: " BM_SECRET || return 1; printf '\n'
  [[ -n $BM_SECRET ]] || { printf 'The password must not be empty.\n'; return 1; }
  read -r -s -p 'Confirm password: ' confirm || return 1; printf '\n'
  [[ $BM_SECRET == "$confirm" ]] || { printf 'Passwords do not match.\n'; BM_SECRET=; return 1; }
  return 0
}

bm_valid_unix_user() { [[ $1 =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }
bm_valid_port() { [[ $1 =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

bm_ipv4_to_int() {
  local a b c d
  [[ $1 =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$1"
  ((10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255)) || return 1
  printf '%u' "$(((10#$a << 24) | (10#$b << 16) | (10#$c << 8) | 10#$d))"
}
bm_int_to_ipv4() { local n=$1; printf '%d.%d.%d.%d' "$((n >> 24 & 255))" "$((n >> 16 & 255))" "$((n >> 8 & 255))" "$((n & 255))"; }

bm_b64() { printf '%s' "$1" | base64 | tr -d '\n'; }

# UTF-16LE base64 for powershell.exe -EncodedCommand.
bm_ps_encode() {
  if command -v iconv >/dev/null 2>&1; then
    printf '%s' "$1" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n'
  else
    printf '%s' "$1" | python3 -c 'import base64,sys; sys.stdout.write(base64.b64encode(sys.stdin.read().encode("utf-16-le")).decode())'
  fi
}

# Private scratch directory, created once in the *calling* shell (never in a
# command substitution, otherwise the EXIT trap would fire immediately).
bm_init_tmp() {
  [[ -n ${BM_TMP:-} && -d $BM_TMP ]] && return 0
  BM_TMP=$(mktemp -d "${TMPDIR:-/tmp}/bootstrap-manager.XXXXXX") || return 1
  chmod 700 "$BM_TMP"
  trap 'bm_cleanup' EXIT
}
bm_cleanup() {
  [[ -n ${BM_TMP:-} ]] && rm -rf -- "$BM_TMP"
  if declare -F bm_extra_cleanup >/dev/null; then bm_extra_cleanup; fi
}
bm_tmpdir() { [[ -n ${BM_TMP:-} && -d $BM_TMP ]] || { bm_err 'bm_init_tmp was not called.'; return 1; }; printf '%s' "$BM_TMP"; }

bm_check_dependencies() {
  local missing=()
  for cmd in ssh scp ssh-keygen timeout base64 mktemp; do command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd"); done
  if ((${#missing[@]})); then bm_err "Missing required command(s): ${missing[*]} (Debian/Ubuntu: sudo apt install openssh-client coreutils)"; return 1; fi
  if ! command -v sshpass >/dev/null 2>&1; then
    local v; v=$(ssh -V 2>&1 | sed -nE 's/^OpenSSH_([0-9]+)\.([0-9]+).*/\1 \2/p')
    read -r major minor <<< "$v"
    if [[ -z $major ]] || ((major < 8 || (major == 8 && minor < 4))); then
      bm_err 'Password logins need sshpass or OpenSSH >= 8.4 (SSH_ASKPASS_REQUIRE). Install sshpass: sudo apt install sshpass'
      return 1
    fi
  fi
  bm_init_tmp
}

# ------------------------------------------------------------ SSH key pair ---
# Sets BM_KEY (private key path) and BM_PUBKEY (public key line).
# Order: $BM_KEY_FILE, then ~/.ssh/id_ed25519, id_ecdsa, id_rsa. If none exists,
# a new ed25519 key without passphrase is generated (unattended automation).
bm_ensure_keypair() {
  local candidate key=
  if [[ -n ${BM_KEY_FILE:-} ]]; then
    key=$BM_KEY_FILE
  else
    for candidate in "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_ecdsa" "$HOME/.ssh/id_rsa"; do
      [[ -f $candidate ]] && { key=$candidate; break; }
    done
    key=${key:-$HOME/.ssh/id_ed25519}
  fi
  if [[ ! -f $key ]]; then
    install -d -m 700 "$(dirname -- "$key")" || return 1
    bm_info "No SSH key pair found. Generating ed25519 key: $key"
    ssh-keygen -q -t ed25519 -N '' -C "ansible@$(uname -n)" -f "$key" || { bm_err "ssh-keygen failed for $key"; return 1; }
  else
    bm_info "Using existing SSH key pair: $key"
  fi
  chmod 600 "$key" 2>/dev/null || true
  if [[ ! -f $key.pub ]]; then
    bm_info "Public key missing; deriving $key.pub from the private key."
    ssh-keygen -y -f "$key" > "$key.pub" || { bm_err "Cannot derive public key from $key"; return 1; }
  fi
  if ! ssh-keygen -y -P '' -f "$key" >/dev/null 2>&1; then
    bm_warn "$key is passphrase-protected. Load it into ssh-agent (ssh-add) so Ansible can run unattended."
  fi
  BM_KEY=$key
  BM_PUBKEY=$(head -n1 "$key.pub" | tr -d '\r')
  [[ $BM_PUBKEY =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)\ [A-Za-z0-9+/=]+ ]] \
    || { bm_err "$key.pub does not contain a supported public key."; return 1; }
}

# ------------------------------------------------------------------ scan ---
# bm_scan FIRST LAST PORT... -> BM_SCAN_RESULTS=("ip|port,port" ...)
bm_scan() {
  local first=$1 last=$2; shift 2
  local first_n last_n n ip port open
  first_n=$(bm_ipv4_to_int "$first") || return 1
  last_n=$(bm_ipv4_to_int "$last") || return 1
  BM_SCAN_RESULTS=()
  for ((n = first_n; n <= last_n; n++)); do
    ip=$(bm_int_to_ipv4 "$n"); open=()
    for port in "$@"; do
      if timeout 1 bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$ip" "$port" 2>/dev/null; then open+=("$port"); fi
    done
    if ((${#open[@]})); then
      BM_SCAN_RESULTS+=("$ip|$(IFS=,; echo "${open[*]}")")
      printf 'Open SSH candidate: %s (port(s): %s)\n' "$ip" "${open[*]}"
    fi
  done
}

# ------------------------------------------------------------ SSH runners ---
bm_ssh_opts() { # port
  BM_SSH_OPTS=(-F /dev/null -o ConnectTimeout="$BM_CONNECT_TIMEOUT" -o ConnectionAttempts=1
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$BM_KNOWN_HOSTS"
    -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -o LogLevel=ERROR)
}

# bm_admin_exec PROG IP PORT USER PASSWORD ARGS...   (PROG: ssh|scp)
# Password empty -> key/agent authentication only (BatchMode).
bm_admin_exec() {
  local prog=$1 ip=$2 port=$3 user=$4 password=$5; shift 5
  local portflag=-p; [[ $prog == scp ]] && portflag=-P
  bm_ssh_opts
  local cmd=("$prog" "${BM_SSH_OPTS[@]}" "$portflag" "$port")
  if [[ -z $password ]]; then
    cmd+=(-o BatchMode=yes -o PreferredAuthentications=publickey)
    [[ -n ${BM_KEY:-} ]] && cmd+=(-i "$BM_KEY")
    [[ $prog == ssh ]] && cmd+=("$user@$ip")
    timeout "${BM_CMD_TIMEOUT:-60}" "${cmd[@]}" "$@"
    return
  fi
  # shellcheck disable=SC2054  # commas are part of the option value
  cmd+=(-o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive -o NumberOfPasswordPrompts=1)
  [[ $prog == ssh ]] && cmd+=("$user@$ip")
  if command -v sshpass >/dev/null 2>&1; then
    SSHPASS=$password timeout "${BM_CMD_TIMEOUT:-60}" sshpass -e "${cmd[@]}" "$@"
  else
    local dir; dir=$(bm_tmpdir) || return 1
    if [[ ! -x $dir/askpass ]]; then
      printf '#!/bin/sh\nprintf "%%s\\n" "$BM_ASKPASS_SECRET"\n' > "$dir/askpass"; chmod 700 "$dir/askpass"
    fi
    BM_ASKPASS_SECRET=$password SSH_ASKPASS=$dir/askpass SSH_ASKPASS_REQUIRE=force DISPLAY=${DISPLAY:-none} \
      timeout "${BM_CMD_TIMEOUT:-60}" "${cmd[@]}" "$@"
  fi
}

# Key-only login with the control node key (used for the Ansible account).
bm_key_exec() { # IP PORT USER CMD...
  local ip=$1 port=$2 user=$3; shift 3
  bm_ssh_opts
  timeout "${BM_CMD_TIMEOUT:-60}" ssh "${BM_SSH_OPTS[@]}" -p "$port" -o BatchMode=yes \
    -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -i "$BM_KEY" "$user@$ip" "$@"
}

bm_hostkey_changed() { [[ $1 == *'REMOTE HOST IDENTIFICATION HAS CHANGED'* || $1 == *'Host key verification failed'* ]]; }

# Offer to remove a stale known_hosts entry. Returns 0 if removed (retry useful).
bm_fix_hostkey() { # IP PORT
  local ip=$1 port=$2 entry=$1
  [[ $port != 22 ]] && entry="[$ip]:$port"
  bm_warn "The SSH host key of $entry differs from the one in $BM_KNOWN_HOSTS."
  bm_warn 'This is expected after reinstalling the host, but can also indicate a man-in-the-middle attack.'
  bm_is_interactive || return 1
  bm_ask_yes_no "Remove the old host key of $entry and accept the new one?" n || return 1
  ssh-keygen -q -R "$entry" -f "$BM_KNOWN_HOSTS" >/dev/null 2>&1
  return 0
}

# --------------------------------------------------------------- facts ---
# bm_gather_facts IP PORT USER  (key login) -> BM_FACT_FAMILY/HOST/PYTHON/OS
# Return: 0 ok, 2 login failed, 3 host key problem, 4 unknown platform
bm_gather_facts() {
  local ip=$1 port=$2 user=$3 out ps
  BM_FACT_FAMILY='' BM_FACT_HOST='' BM_FACT_PYTHON='' BM_FACT_OS=''
  out=$(bm_key_exec "$ip" "$port" "$user" \
    'echo BMFACT_OS=$(uname -s); echo BMFACT_HOST=$(uname -n); echo BMFACT_PY=$(command -v python3 || command -v python); echo BMFACT_NAME=$(. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME")' 2>&1)
  bm_hostkey_changed "$out" && { BM_LAST_OUTPUT=$out; return 3; }
  out=${out//$'\r'/}
  if [[ $out == *BMFACT_OS=Linux* ]]; then
    BM_FACT_FAMILY=linux
    BM_FACT_HOST=$(sed -n 's/^BMFACT_HOST=//p' <<< "$out" | head -n1)
    BM_FACT_PYTHON=$(sed -n 's/^BMFACT_PY=//p' <<< "$out" | head -n1)
    BM_FACT_OS=$(sed -n 's/^BMFACT_NAME=//p' <<< "$out" | head -n1)
    return 0
  fi
  [[ $out == *'Permission denied'* || $out == *'Connection refused'* || $out == *'timed out'* ]] && { BM_LAST_OUTPUT=$out; return 2; }
  ps="[Console]::WriteLine('BMFACT_OS=Windows'); [Console]::WriteLine('BMFACT_HOST=' + \$env:COMPUTERNAME); [Console]::WriteLine('BMFACT_NAME=' + [Environment]::OSVersion.VersionString)"
  out=$(bm_key_exec "$ip" "$port" "$user" "powershell.exe -NoProfile -NonInteractive -EncodedCommand $(bm_ps_encode "$ps")" 2>&1)
  out=${out//$'\r'/}
  if [[ $out == *BMFACT_OS=Windows* ]]; then
    BM_FACT_FAMILY=windows
    BM_FACT_HOST=$(sed -n 's/^BMFACT_HOST=//p' <<< "$out" | head -n1)
    BM_FACT_OS=$(sed -n 's/^BMFACT_NAME=//p' <<< "$out" | head -n1)
    return 0
  fi
  BM_LAST_OUTPUT=$out
  return 4
}

# Checks privilege escalation with the account password (Linux: sudo).
bm_verify_become() { # IP PORT USER PASSWORD
  printf '%s\n' "$4" | bm_key_exec "$1" "$2" "$3" "sudo -k -S -p '' true" >/dev/null 2>&1
}

# ------------------------------------------------------------- detect OS ---
# bm_detect_os IP PORT ADMIN_USER ADMIN_PASSWORD -> BM_OS_ID, BM_OS_NAME, BM_OS_FAMILY
# Return: 0 ok, 2 auth failed, 3 host key, 4 unsupported, 5 unreachable
bm_detect_os() {
  local ip=$1 port=$2 user=$3 password=$4 out ps
  BM_OS_ID='' BM_OS_NAME='' BM_OS_FAMILY=''
  out=$(bm_admin_exec ssh "$ip" "$port" "$user" "$password" 'cat /etc/os-release 2>/dev/null; uname -s 2>/dev/null' 2>&1)
  BM_LAST_OUTPUT=$out
  bm_hostkey_changed "$out" && return 3
  if [[ $out == *'ID='* && $out == *Linux* ]]; then
    BM_OS_FAMILY=linux
    BM_OS_ID=$(sed -n 's/^ID=//p' <<< "$out" | head -n1 | tr -d '"' | tr '[:upper:]' '[:lower:]')
    BM_OS_NAME=$(sed -n 's/^PRETTY_NAME=//p' <<< "$out" | head -n1 | tr -d '"')
    return 0
  fi
  [[ $out == *'Permission denied'* || $out == *'Authentication failed'* ]] && return 2
  [[ $out == *'Connection refused'* || $out == *'timed out'* || $out == *'No route to host'* ]] && return 5
  ps="[Console]::WriteLine('BMWIN;' + [Environment]::OSVersion.VersionString)"
  out=$(bm_admin_exec ssh "$ip" "$port" "$user" "$password" "powershell.exe -NoProfile -NonInteractive -EncodedCommand $(bm_ps_encode "$ps")" 2>&1)
  out=${out//$'\r'/}
  BM_LAST_OUTPUT=$out
  if [[ $out == *BMWIN\;* ]]; then
    BM_OS_FAMILY=windows BM_OS_ID=windows
    BM_OS_NAME=$(sed -n 's/^.*BMWIN;//p' <<< "$out" | head -n1)
    return 0
  fi
  [[ $out == *'Permission denied'* ]] && return 2
  return 4
}

# -------------------------------------------------------------- providers ---
# Sets BM_PROVIDER_ID/KIND/URL for BM_OS_ID.
bm_select_provider() {
  local record id pattern kind url
  BM_PROVIDER_ID='' BM_PROVIDER_KIND='' BM_PROVIDER_URL=''
  for record in "${BOOTSTRAP_PROVIDERS[@]}"; do
    IFS='|' read -r id pattern kind url <<< "$record"
    if [[ $BM_OS_ID =~ ^($pattern)$ ]]; then BM_PROVIDER_ID=$id BM_PROVIDER_KIND=$kind BM_PROVIDER_URL=$url; return 0; fi
  done
  return 1
}

# Provider script as a local file: a sibling checkout wins (reviewed, pinned),
# otherwise it is downloaded once on the control node. Targets need no curl.
bm_provider_file() {
  local url=$BM_PROVIDER_URL repo file dir candidate dest
  if [[ $url == file://* ]]; then candidate=${url#file://}; [[ -r $candidate ]] && { BM_PROVIDER_FILE=$candidate; return 0; }; fi
  if [[ $url =~ ^https://raw\.githubusercontent\.com/[^/]+/([^/]+)/[^/]+/(.+)$ ]]; then
    repo=${BASH_REMATCH[1]} file=${BASH_REMATCH[2]}
    for dir in ${BOOTSTRAP_PROVIDER_DIR:+"$BOOTSTRAP_PROVIDER_DIR"} "$BM_ROOT_DIR/.." "$BM_ROOT_DIR/vendor"; do
      candidate="$dir/$repo/$file"
      [[ -r $candidate ]] && { BM_PROVIDER_FILE=$(cd -- "$(dirname -- "$candidate")" && pwd)/$(basename -- "$candidate"); return 0; }
    done
  fi
  dest="$(bm_tmpdir)/provider-$BM_PROVIDER_ID" || return 1
  if [[ ! -s $dest ]]; then
    command -v curl >/dev/null 2>&1 || { bm_err "curl is required to download $url"; return 1; }
    curl -fsSL "$url" -o "$dest" || { bm_err "Could not download provider script: $url"; return 1; }
  fi
  BM_PROVIDER_FILE=$dest
}

bm_sq() { local v=$1; printf "'%s'" "${v//\'/\'\\\'\'}"; }

# Remote POSIX wrapper: reads admin password and account password from stdin,
# stores the provider script that follows on stdin in a private temp file and
# runs it as root (directly, via passwordless sudo, or via sudo -S).
bm_linux_wrapper() { # USER PUBKEY SUDO_MODE
  local args
  args="username=$(bm_sq "$1") ssh_public_key=$(bm_sq "$2") sudo_mode=$(bm_sq "$3") password_stdin=1"
  cat <<EOF
IFS= read -r BM_AP || exit 90
IFS= read -r BM_NP || exit 90
umask 077
tmp=\$(mktemp "\${TMPDIR:-/tmp}/ansible-bootstrap.XXXXXX") || exit 91
trap 'rm -f "\$tmp"' EXIT HUP INT TERM
cat > "\$tmp" || exit 92
[ -s "\$tmp" ] || { echo 'Provider script was not received.' >&2; exit 92; }
command -v bash >/dev/null 2>&1 || { echo 'bash is required on the target.' >&2; exit 93; }
if [ "\$(id -u)" -eq 0 ]; then
  printf '%s\n' "\$BM_NP" | bash "\$tmp" $args
elif command -v sudo >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    printf '%s\n' "\$BM_NP" | sudo -n bash "\$tmp" $args
  elif [ -n "\$BM_AP" ]; then
    printf '%s\n' "\$BM_AP" | sudo -k -S -p '' true 2>/dev/null || { echo 'sudo rejected the administrator password.' >&2; exit 43; }
    { printf '%s\n' "\$BM_AP"; printf '%s\n' "\$BM_NP"; } | sudo -k -S -p '' bash "\$tmp" $args
  else
    echo 'sudo requires a password for this administrator account.' >&2; exit 41
  fi
else
  echo 'Log in as root or as an account that can use sudo.' >&2; exit 42
fi
EOF
}

bm_run_linux_provider() { # IP PORT ADMIN_USER ADMIN_PW NEW_USER NEW_PW SUDO_MODE [SUDO_PW]
  local ip=$1 port=$2 au=$3 ap=$4 nu=$5 np=$6 mode=$7 sp=${8-$4} wrapper remote
  wrapper=$(bm_linux_wrapper "$nu" "$BM_PUBKEY" "$mode")
  remote="sh -c \"\$(echo $(bm_b64 "$wrapper") | base64 -d)\""
  { printf '%s\n%s\n' "$sp" "$np"; cat -- "$BM_PROVIDER_FILE"; } \
    | BM_CMD_TIMEOUT=$BM_BOOTSTRAP_TIMEOUT bm_admin_exec ssh "$ip" "$port" "$au" "$ap" "$remote" 2>&1
}

# PowerShell stub run on Windows: reads and deletes the uploaded parameter file,
# runs the uploaded provider script elevated, removes both files, returns exit code.
bm_windows_stub() { # TAG
  local tag=$1
  cat <<EOF
\$ErrorActionPreference = 'Stop'
\$s = Join-Path \$HOME 'ab-$tag.ps1'; \$t = Join-Path \$HOME 'ab-$tag.txt'; \$rc = 1
try {
  \$f = (Get-Content -LiteralPath \$t -Raw).Trim().Split(';')
  Remove-Item -LiteralPath \$t -Force
  \$d = { param(\$x) [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(\$x)) }
  & \$s -Username (& \$d \$f[0]) -Password (& \$d \$f[1]) -PublicKey (& \$d \$f[2])
  \$rc = 0
} catch { [Console]::Error.WriteLine(\$_.Exception.Message) }
finally { Remove-Item -LiteralPath \$s, \$t -Force -ErrorAction SilentlyContinue }
exit \$rc
EOF
}

# Windows: upload script + parameter file via scp (works with cmd or PowerShell
# as default shell), then run it elevated through an encoded PowerShell stub.
bm_run_windows_provider() { # IP PORT ADMIN_USER ADMIN_PW NEW_USER NEW_PW
  local ip=$1 port=$2 au=$3 ap=$4 nu=$5 np=$6 dir tag stub rc
  dir=$(bm_tmpdir) || return 1
  tag=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  cp -- "$BM_PROVIDER_FILE" "$dir/ab-$tag.ps1"
  printf '%s;%s;%s' "$(bm_b64 "$nu")" "$(bm_b64 "$np")" "$(bm_b64 "$BM_PUBKEY")" > "$dir/ab-$tag.txt"
  chmod 600 "$dir/ab-$tag.ps1" "$dir/ab-$tag.txt"
  if ! bm_admin_exec scp "$ip" "$port" "$au" "$ap" "$dir/ab-$tag.ps1" "$dir/ab-$tag.txt" "$au@$ip:" 2>&1; then
    rm -f -- "$dir/ab-$tag.txt"; echo 'Upload via scp/sftp failed.' >&2; return 94
  fi
  rm -f -- "$dir/ab-$tag.txt"
  stub=$(bm_windows_stub "$tag")
  BM_CMD_TIMEOUT=$BM_BOOTSTRAP_TIMEOUT bm_admin_exec ssh "$ip" "$port" "$au" "$ap" \
    "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $(bm_ps_encode "$stub")" 2>&1
  rc=$?
  return "$rc"
}

# --------------------------------------------------------- full bootstrap ---
# bm_bootstrap_host IP PORT ADMIN_USER ADMIN_PW NEW_USER NEW_PW [SUDO_MODE]
# Requires bm_ensure_keypair. Sets BM_OS_FAMILY etc. Returns 0 when the new
# account accepts the control node key afterwards.
bm_bootstrap_host() {
  local ip=$1 port=$2 au=$3 ap=$4 nu=$5 np=$6 mode=${7:-vault} rc out attempt
  [[ $np != *$'\n'* ]] || { bm_err 'Passwords must not contain line breaks.'; return 1; }
  for attempt in 1 2; do
    bm_detect_os "$ip" "$port" "$au" "$ap"; rc=$?
    if ((rc == 3)) && ((attempt == 1)) && bm_fix_hostkey "$ip" "$port"; then continue; fi
    break
  done
  case $rc in
    0) ;;
    2) bm_err "Administrator login as $au@$ip:$port failed."; return 2 ;;
    3) bm_err "Host key verification failed for $ip:$port."; return 3 ;;
    5) bm_err "$ip:$port is not reachable."; return 5 ;;
    *) bm_err "Could not identify a supported operating system on $ip:$port."
       printf '%s\n' "$BM_LAST_OUTPUT" | tail -n 5 >&2; return 4 ;;
  esac
  bm_info "Detected platform: ${BM_OS_NAME:-$BM_OS_ID}"
  bm_select_provider || { bm_err "No bootstrap provider configured for OS id '$BM_OS_ID'."; return 6; }
  bm_provider_file || return 6
  bm_info "Running provider '$BM_PROVIDER_ID' on $ip (this can take several minutes)..."
  if [[ $BM_PROVIDER_KIND == powershell ]]; then
    out=$(bm_run_windows_provider "$ip" "$port" "$au" "$ap" "$nu" "$np"); rc=$?
  elif [[ $BM_PROVIDER_KIND == shell ]]; then
    local sp=$ap
    out=$(bm_run_linux_provider "$ip" "$port" "$au" "$ap" "$nu" "$np" "$mode" "$sp"); rc=$?
    # Admin logged in with a key but sudo wants a password: ask for it once.
    if ((rc == 41 || rc == 43)) && bm_is_interactive; then
      printf '%s\n' "$out" | tail -n 1 >&2
      read -r -s -p "sudo password for $au@$ip: " sp; printf '\n'
      out=$(bm_run_linux_provider "$ip" "$port" "$au" "$ap" "$nu" "$np" "$mode" "$sp"); rc=$?
    fi
    [[ -n $sp ]] && out=${out//"$sp"/[redacted]}
  else
    bm_err "Provider $BM_PROVIDER_ID has unknown kind '$BM_PROVIDER_KIND'."; return 6
  fi
  [[ -n $np ]] && out=${out//"$np"/[redacted]}
  [[ -n $ap ]] && out=${out//"$ap"/[redacted]}
  if ((rc != 0)); then
    bm_err "Bootstrap failed on $ip (exit $rc). Last output:"
    printf '%s\n' "$out" | tail -n 30 >&2
    return 7
  fi
  printf '%s\n' "$out" | grep -E '^\[|Created|Installed|Bootstrap' | tail -n 8
  if bm_key_exec "$ip" "$port" "$nu" exit >/dev/null 2>&1; then
    bm_info "Key-based login as $nu@$ip works."
    return 0
  fi
  bm_err "Bootstrap finished, but key-based login as $nu@$ip:$port does not work."
  return 8
}
