#!/bin/bash
# Mac -> Windows lab helper for the D120 batch.
# Reuses the SSH multiplexed socket opened by ~/Downloads/Domenia-lab/relais.sh (password typed once by the user).
# Never stores or passes a password. Only touches C:\Users\degun\domenia-lab\work\<LAB_DIR> on the lab host.
#
#   lab.sh sync                 copy the working tree (tracked + untracked, not ignored) to the lab
#   lab.sh ps  'PS command'     run a Windows PowerShell 5.1 command from <LAB_DIR>\dev
#   lab.sh file local.ps1 args  run a local script on the lab (copied next to the tree) from <LAB_DIR>\dev
#   lab.sh get remote local     copy a file back (remote path relative to <LAB_DIR>)
set -u
HOST="${DOMENIA_LAB_HOST:-degun@192.168.1.173}"
SOCK="${DOMENIA_LAB_SOCK:-$(ls -t /tmp/domenia-lab-*.sock 2>/dev/null | head -1)}"
LAB_DIR="${LAB_DIR:-d120}"
REMOTE="C:\\Users\\degun\\domenia-lab\\work\\$LAB_DIR"
REMOTE_FWD="domenia-lab/work/$LAB_DIR"
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
[ -S "$SOCK" ] || { echo "lab.sh: no relay socket (start ~/Downloads/Domenia-lab/relais.sh)" >&2; exit 90; }
SSH=(ssh -o ControlPath="$SOCK" -o BatchMode=yes "$HOST")
SCP=(scp -q -o ControlPath="$SOCK" -o BatchMode=yes)

case "${1:-}" in
  sync)
    tmp="$(mktemp -d)"; tarball="$tmp/tree.tar"
    (cd "$ROOT" && { git ls-files -z; git ls-files -z --others --exclude-standard; } | \
       grep -zv '__pycache__' | COPYFILE_DISABLE=1 xargs -0 tar --no-mac-metadata -cf "$tarball" 2>/dev/null) || { echo "tar failed" >&2; exit 91; }
    "${SSH[@]}" "powershell -NoProfile -Command \"if (Test-Path '$REMOTE') { Remove-Item -LiteralPath '$REMOTE' -Recurse -Force }; New-Item -ItemType Directory -Path '$REMOTE' | Out-Null\"" || exit 92
    "${SCP[@]}" "$tarball" "$HOST:$REMOTE_FWD/tree.tar" || exit 93
    "${SSH[@]}" "tar -xf $REMOTE\\tree.tar -C $REMOTE && del $REMOTE\\tree.tar" || exit 94
    rm -rf "$tmp"; echo "synced -> $REMOTE" ;;
  ps)
    shift; tmp="$(mktemp -d)"; f="$tmp/cmd.ps1"
    printf '\xef\xbb\xbf$ErrorActionPreference = "Continue"\nSet-Location -LiteralPath "%s\\dev"\n%s\n' "$REMOTE" "$*" > "$f"
    "${SCP[@]}" "$f" "$HOST:$REMOTE_FWD/_cmd.ps1" || exit 93
    "${SSH[@]}" "powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $REMOTE\\_cmd.ps1"; rc=$?
    rm -rf "$tmp"; exit $rc ;;
  file)
    shift; src="$1"; shift; base="$(basename "$src")"
    "${SCP[@]}" "$src" "$HOST:$REMOTE_FWD/_$base" || exit 93
    "${SSH[@]}" "cd /d $REMOTE\\dev && powershell -NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File $REMOTE\\_$base $*"; exit $? ;;
  get)
    shift; "${SCP[@]}" "$HOST:$REMOTE_FWD/$1" "$2"; exit $? ;;
  *) sed -n '2,10p' "$0"; exit 2 ;;
esac
