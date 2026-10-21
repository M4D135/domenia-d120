#!/bin/bash
# Single entry point to the Domenia VM for a team working in parallel (docs/PLATFORM.md § 6). The VM has 4 vCPU and
# 8 GB: every command takes an exclusive lock on the Mac first, so batches run one after another, never together.
#
#   tools/vm.sh <lot> build   [--config Debug|Release|both] [--no-sync]
#   tools/vm.sh <lot> publish [--zip] [--no-sync]
#   tools/vm.sh <lot> capture [--routes r1,r2] [--themes dark,light,contrast] [--pack] [--out DIR] [--no-sync]
#   tools/vm.sh <lot> test    [--config Debug|Release] [--no-sync]      (tests: only at the very end, decision of 21/10)
#
# <lot>: lower case letters, digits and dashes (40 at most). Sources go to C:\DomeniaDev\src\<lot>\v2 (mirror of the tree
# that holds this script, worktrees included), the pack to C:\DomeniaDev\out\<lot>, the images to
# C:\DomeniaDev\captures\<lot>. « capture » syncs, builds Release (or publishes with --pack), runs the capture in
# simulation, then copies the images and capture.log into DIR (--out) when given.
#
# Environment: DOMENIA_VM_HOST (ssh host, default domenia-vm), DOMENIA_VM_LOCK (lock path, a symbolic link, default
# /tmp/domenia-vm.lock), DOMENIA_VM_LOCK_WAIT (seconds to wait for the lock, default 3600), DOMENIA_VM_LOCK_STALE
# (seconds after which a lock whose owner cannot be checked is taken as dead, default 7200), DOMENIA_VM_DRY_RUN=1
# (takes the lock and prints the remote commands without running them; DOMENIA_VM_DRY_RUN_HOLD=N keeps the lock N s).
set -uo pipefail

TOOLS=$(cd "$(dirname "$0")" && pwd)
HOST=${DOMENIA_VM_HOST:-domenia-vm}
LOCK=${DOMENIA_VM_LOCK:-/tmp/domenia-vm.lock}
LOCK_WAIT=${DOMENIA_VM_LOCK_WAIT:-3600}
LOCK_STALE=${DOMENIA_VM_LOCK_STALE:-7200}
POLL=${DOMENIA_VM_LOCK_POLL:-5}
DRY=${DOMENIA_VM_DRY_RUN:-0}
HOLD=${DOMENIA_VM_DRY_RUN_HOLD:-0}

usage() {
  # The comment block at the top of this file.
  awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0" >&2
  exit 64
}

fail() {
  echo "vm.sh : $*" >&2
  exit 1
}

[ $# -ge 2 ] || usage
LOT=$1
CMD=$2
shift 2
[[ "$LOT" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]] || { echo "vm.sh : lot invalide (minuscules, chiffres et tirets, 40 caractères au plus)." >&2; exit 64; }
# Reserved: « cache » (sync-vm.sh cache), « v2 » and « domenia » (they would mix with the historical folders of the VM:
# C:\DomeniaDev\src\v2 and C:\DomeniaDev\out\Domenia, NTFS ignoring case).
case "$LOT" in
  cache|v2|domenia) echo "vm.sh : « $LOT » est un nom réservé (cache, v2, domenia)." >&2; exit 64 ;;
esac
case "$CMD" in build|publish|capture|test) ;; *) usage ;; esac

CONFIG=""
ZIP=0
SYNC=1
PACK=0
ROUTES=""
THEMES=""
OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --config) [ $# -ge 2 ] || usage; CONFIG=$2; shift 2 ;;
    --zip) ZIP=1; shift ;;
    --no-sync) SYNC=0; shift ;;
    --pack) PACK=1; shift ;;
    --routes) [ $# -ge 2 ] || usage; ROUTES=$2; shift 2 ;;
    --themes) [ $# -ge 2 ] || usage; THEMES=$2; shift 2 ;;
    --out) [ $# -ge 2 ] || usage; OUT=$2; shift 2 ;;
    *) echo "vm.sh : option inconnue : $1" >&2; usage ;;
  esac
done
case "$CMD:$CONFIG" in
  build:) CONFIG=Debug ;;
  test:) CONFIG=Debug ;;
  capture:) CONFIG=Release ;;
  build:Debug|build:Release|build:both|test:Debug|test:Release) ;;
  *:) ;;
  *) fail "configuration non admise pour $CMD : $CONFIG" ;;
esac
# Checked here as well as in the VM: nothing outside these forms is ever sent.
# (Bounds above 255 are not portable in bash regular expressions: the length is checked apart. 2 000 characters keep the
# encoded PowerShell command under the 8 191 characters of a cmd.exe line, the shell of the VM's SSH server.)
if [ -n "$ROUTES" ] && { [ ${#ROUTES} -gt 2000 ] || ! [[ "$ROUTES" =~ ^[A-Za-z0-9=\&%._,?-]{2,}$ ]]; }; then fail "écrans invalides (--routes : 2 000 caractères au plus)"; fi
if [ -n "$THEMES" ] && ! [[ "$THEMES" =~ ^(dark|light|contrast)(,(dark|light|contrast)){0,2}$ ]]; then fail "thèmes invalides (--themes) : dark, light, contrast"; fi
if [ -n "$THEMES" ] && [ -z "$ROUTES" ]; then fail "--themes s’applique aux écrans de --routes"; fi
if [ "$CMD" != "capture" ] && { [ -n "$ROUTES$THEMES$OUT" ] || [ $PACK -eq 1 ]; }; then fail "--routes, --themes, --pack et --out ne valent que pour capture"; fi
if [ "$CMD" != "publish" ] && [ $ZIP -eq 1 ]; then fail "--zip ne vaut que pour publish"; fi

SRC="C:\\DomeniaDev\\src\\$LOT\\v2"
TOOLS_VM="$SRC\\tools"

# ---------------------------------------------------------------- lock

# The lock is a symbolic link created in one step with its owner as target: « pid host start lot command » (no slash).
# symlink(2) fails when the path exists, so taking the lock and naming its owner are one atomic operation: a lock never
# exists without its owner. A lock is removed only by its owner, or, once dead, under the takeover lock
# ($LOCK.takeover, same kind) after reading it again: a live lock is never renamed nor removed by a waiter.
OWNED=0
TOKEN=""
TAKEOVER="$LOCK.takeover"

# Owner of a lock path: the link target, or the « owner » file of a lock folder left by an earlier version of this script.
owner_of() {
  if [ -L "$1" ]; then
    readlink "$1" 2>/dev/null || true
  elif [ -d "$1" ]; then
    cat "$1/owner" 2>/dev/null || true
  fi
}

# True when the holder named by an owner line is certainly gone: its process no longer exists on this Mac, or the lock
# is older than its limit (LOCK_STALE, or 60 s for an owner line that cannot be read).
owner_is_dead() {
  local line=$1 limit=$2 pid host start _rest now
  now=$(date +%s)
  read -r pid host start _rest <<<"$line"
  if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! [[ "$start" =~ ^[0-9]+$ ]]; then
    # No readable owner (legacy folder still being created, or garbage): judged on the age of the path itself.
    local mtime
    mtime=$(stat -f %m "$3" 2>/dev/null || stat -c %Y "$3" 2>/dev/null || echo "$now")
    [ $(( now - mtime )) -gt 60 ]
    return
  fi
  if [ $(( now - start )) -gt "$limit" ]; then
    return 0
  fi
  if [ "$host" = "$(hostname -s)" ] && ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi
  return 1
}

# Creates a lock link; true only if this call created it (never inside a folder that took the place meanwhile).
create_link() {
  local target=$1 path=$2
  ln -s "$target" "$path" 2>/dev/null || return 1
  if [ -L "$path" ] && [ "$(readlink "$path" 2>/dev/null)" = "$target" ]; then
    return 0
  fi
  # « ln » followed a folder created in between (legacy lock) and made the link inside it: removed, not ours.
  [ -L "$path/$target" ] && rm -f "$path/$target"
  return 1
}

# Removes the lock at $LOCK if it is still the dead one that was seen. True when removed.
remove_dead_lock() {
  local seen=$1 token now
  now=$(date +%s)
  token="$$ $(hostname -s) $now takeover"
  if ! create_link "$token" "$TAKEOVER"; then
    # Another waiter is taking over; a takeover left by a vanished process is cleared for the next round.
    local holder
    holder=$(owner_of "$TAKEOVER")
    if [ -n "$holder" ] && owner_is_dead "$holder" 60 "$TAKEOVER" && [ "$(owner_of "$TAKEOVER")" = "$holder" ]; then
      rm -f "$TAKEOVER"
    fi
    return 1
  fi
  local removed=1
  # Read again under the takeover lock: only an owner releases its own lock, and a new lock cannot be created while this
  # one exists, so the lock cannot change between this check and its removal.
  if [ "$(owner_of "$LOCK")" = "$seen" ]; then
    if [ -L "$LOCK" ]; then
      rm -f "$LOCK" && removed=0
    elif [ -d "$LOCK" ]; then
      rm -rf "$LOCK" && removed=0
    fi
  fi
  [ "$(readlink "$TAKEOVER" 2>/dev/null)" = "$token" ] && rm -f "$TAKEOVER"
  return $removed
}

release_lock() {
  if [ $OWNED -eq 1 ]; then
    if [ "$(readlink "$LOCK" 2>/dev/null)" = "$TOKEN" ]; then
      rm -f "$LOCK"
    fi
    OWNED=0
  fi
}

acquire_lock() {
  local waited=0 quick=0 line parent
  parent=$(dirname "$LOCK")
  # A folder that does not exist or cannot be written would make every attempt fail forever.
  if [ ! -d "$parent" ] || [ ! -w "$parent" ]; then
    fail "dossier du verrou absent ou non inscriptible : $parent (DOMENIA_VM_LOCK)."
  fi
  TOKEN="$$ $(hostname -s) $(date +%s) $LOT $CMD"
  while ! create_link "$TOKEN" "$LOCK"; do
    line=$(owner_of "$LOCK")
    # Released between the attempt and the read, or a dead lock just removed: tried again at once, a few times only, so
    # a link that cannot be created for another reason still goes through the bounded wait below.
    if [ -z "$line" ] && [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ] && [ $quick -lt 3 ]; then
      quick=$(( quick + 1 ))
      continue
    fi
    if { [ -n "$line" ] || [ -L "$LOCK" ] || [ -e "$LOCK" ]; } && owner_is_dead "$line" "$LOCK_STALE" "$LOCK" && remove_dead_lock "$line"; then
      echo "vm.sh : verrou mort retiré (${line:-propriétaire inconnu})." >&2
      if [ $quick -lt 3 ]; then
        quick=$(( quick + 1 ))
        continue
      fi
    fi
    # Every other case waits, and the wait is bounded, even when a dead lock could not be removed.
    if [ "$waited" -ge "$LOCK_WAIT" ]; then
      fail "VM occupée depuis plus de ${LOCK_WAIT} s (${line:-propriétaire inconnu}) ; rien n’a été lancé."
    fi
    if [ $(( waited % 60 )) -eq 0 ]; then
      echo "vm.sh : VM occupée (${line:-propriétaire inconnu}), attente…" >&2
    fi
    sleep "$POLL"
    waited=$(( waited + POLL ))
    quick=0
  done
  OWNED=1
}

trap release_lock EXIT
trap 'release_lock; exit 130' INT
trap 'release_lock; exit 143' TERM HUP

# ---------------------------------------------------------------- remote PowerShell

# Runs a PowerShell command in the VM through -EncodedCommand: no quoting by cmd.exe; the exit code of the script is
# kept, and a script stopped by an error gives 1, never 0.
remote_ps() {
  local script encoded
  script="\$ProgressPreference = 'SilentlyContinue'; try { $1; exit \$LASTEXITCODE } catch { Write-Output ('Erreur : ' + \$_.Exception.Message); exit 1 }"
  if [ "$DRY" = "1" ]; then
    echo "[essai] PowerShell : $1"
    return 0
  fi
  encoded=$(printf '%s' "$script" | iconv -f UTF-8 -t UTF-16LE | base64 | tr -d '\n')
  ssh -o BatchMode=yes "$HOST" "powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
}

# PowerShell single-quoted literal.
ps_quote() {
  printf "'%s'" "${1//\'/\'\'}"
}

run_build() {
  remote_ps "& $(ps_quote "$TOOLS_VM\\build-vm.ps1") -Configuration $1 $2" || fail "compilation $1 en échec (lot $LOT)."
}

# ---------------------------------------------------------------- commands

acquire_lock
started=$(date +%s)
echo "vm.sh : lot $LOT, $CMD — VM réservée."
if [ "$DRY" = "1" ] && [ "$HOLD" -gt 0 ]; then
  sleep "$HOLD"
fi
if [ $SYNC -eq 1 ]; then
  if [ "$DRY" = "1" ]; then
    echo "[essai] synchronisation : $TOOLS/sync-vm.sh $LOT"
  else
    "$TOOLS/sync-vm.sh" "$LOT" || fail "synchronisation en échec (lot $LOT)."
  fi
fi
case "$CMD" in
  build)
    if [ "$CONFIG" = "both" ]; then
      run_build Debug ""
      run_build Release ""
    else
      run_build "$CONFIG" ""
    fi
    ;;
  test)
    run_build "$CONFIG" "-Test"
    ;;
  publish)
    run_build Release "-Publish$([ $ZIP -eq 1 ] && echo ' -Zip')"
    ;;
  capture)
    if [ $PACK -eq 1 ]; then
      run_build Release "-Publish"
      exe="C:\\DomeniaDev\\out\\$LOT\\Domenia\\Domenia.exe"
    else
      run_build Release ""
      exe="$SRC\\src\\Domenia.App\\bin\\x64\\Release\\net10.0-windows\\win-x64\\Domenia.exe"
    fi
    args="-Exe $(ps_quote "$exe") -Clean"
    [ -z "$ROUTES" ] || args="$args -Routes $(ps_quote "$ROUTES")"
    [ -z "$THEMES" ] || args="$args -Themes $(ps_quote "$THEMES")"
    remote_ps "& $(ps_quote "$TOOLS_VM\\capture-vm.ps1") $args"
    code=$?
    if [ -n "$OUT" ] && [ "$DRY" = "1" ]; then
      echo "[essai] copie de C:\\DomeniaDev\\captures\\$LOT vers $OUT"
    elif [ -n "$OUT" ]; then
      mkdir -p "$OUT" || fail "dossier local impossible à créer : $OUT"
      # Images and capture.log only, from the folder of this lot.
      if ssh -o BatchMode=yes "$HOST" "tar -cf - -C C:/DomeniaDev/captures/$LOT ." | tar -xf - -C "$OUT"; then
        echo "vm.sh : captures copiées dans $OUT."
      else
        fail "copie des captures en échec (lot $LOT)."
      fi
    else
      echo "vm.sh : captures laissées dans C:\\DomeniaDev\\captures\\$LOT (--out DIR pour les rapatrier)."
    fi
    [ $code -eq 0 ] || fail "capture terminée avec le code $code (voir capture.log)."
    ;;
esac
echo "vm.sh : lot $LOT, $CMD terminé en $(( $(date +%s) - started )) s."
