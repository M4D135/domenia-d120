#!/bin/bash
# Mac -> test VM helper for the D120 batch. Tests run INSIDE the VirtualBox guest (default CNAMTS-W11-01), never on the host.
# Path: Mac --(SSH socket opened by ~/Downloads/Domenia-lab/relais.sh)--> lab host --(VBoxManage guestcontrol)--> guest.
# The host only stages files in C:\Users\degun\domenia-lab\vmstage. No password is stored, read or passed here:
# the guest account and the PATH of its password file are configured on the host in domenia-lab\vm\vm.conf.json.
#
#   lab.sh setup                deploy vmctl.ps1 to the host (C:\Users\degun\domenia-lab\vm)
#   lab.sh status               VM state
#   lab.sh sync                 copy the working tree (tracked + untracked, not ignored) to C:\DomeniaLab\<LAB_DIR> in the guest
#   lab.sh ps  'PS command'     run a Windows PowerShell 5.1 command (STA) in the guest from <LAB_DIR>\dev
#   lab.sh file local.ps1       run a local script in the guest from <LAB_DIR>\dev
#   lab.sh get remote localdir  copy a guest path (relative to <LAB_DIR>) back to the Mac
set -u
HOST="${DOMENIA_LAB_HOST:-degun@192.168.1.173}"
SOCK="${DOMENIA_LAB_SOCK:-$(ls -t /tmp/domenia-lab-*.sock 2>/dev/null | head -1)}"
LAB_DIR="${LAB_DIR:-d120}"
VM="${DOMENIA_VM:-CNAMTS-W11-01}"
STAGE_FWD="domenia-lab/vmstage"
STAGE='C:\Users\degun\domenia-lab\vmstage'
CTL='C:\Users\degun\domenia-lab\vm\vmctl.ps1'
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
case "$LAB_DIR" in *[!A-Za-z0-9_-]*|"") echo "lab.sh: LAB_DIR invalide" >&2; exit 2;; esac
[ -S "$SOCK" ] || { echo "lab.sh: no relay socket (start ~/Downloads/Domenia-lab/relais.sh)" >&2; exit 90; }
SSH=(ssh -o ControlPath="$SOCK" -o BatchMode=yes "$HOST")
SCP=(scp -q -o ControlPath="$SOCK" -o BatchMode=yes)
ctl() { "${SSH[@]}" "powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $CTL $* -Vm $VM -Name $LAB_DIR"; }
tag="$LAB_DIR-$$-$RANDOM"

case "${1:-}" in
  setup)
    "${SSH[@]}" "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path C:\\Users\\degun\\domenia-lab\\vm,$STAGE | Out-Null\"" || exit 92
    "${SCP[@]}" "$HERE/vmctl.ps1" "$HOST:domenia-lab/vm/vmctl.ps1" && echo "vmctl deployed" ;;
  status) ctl status ;;
  sync)
    tmp="$(mktemp -d)"; tarball="$tmp/tree.tar"
    (cd "$ROOT" && { git ls-files -z; git ls-files -z --others --exclude-standard; } | \
       grep -zv '__pycache__' | COPYFILE_DISABLE=1 xargs -0 tar --no-mac-metadata -cf "$tarball" 2>/dev/null) || { echo "tar failed" >&2; exit 91; }
    "${SCP[@]}" "$tarball" "$HOST:$STAGE_FWD/$tag.tar" || exit 93
    ctl push -Tar "$STAGE\\$tag.tar"; rc=$?
    "${SSH[@]}" "del $STAGE\\$tag.tar" >/dev/null 2>&1; rm -rf "$tmp"; exit $rc ;;
  ps)
    shift; tmp="$(mktemp -d)"; f="$tmp/_cmd-$tag.ps1"
    printf '\xef\xbb\xbf$ErrorActionPreference = "Continue"\n%s\n' "$*" > "$f"
    "${SCP[@]}" "$f" "$HOST:$STAGE_FWD/_cmd-$tag.ps1" || exit 93
    ctl run -Sta -Script "$STAGE\\_cmd-$tag.ps1"; rc=$?
    "${SSH[@]}" "del $STAGE\\_cmd-$tag.ps1" >/dev/null 2>&1; rm -rf "$tmp"; exit $rc ;;
  file)
    shift; src="$1"; base="_$(basename "$src" .ps1)-$tag.ps1"
    "${SCP[@]}" "$src" "$HOST:$STAGE_FWD/$base" || exit 93
    ctl run -Sta -Script "$STAGE\\$base"; rc=$?
    "${SSH[@]}" "del $STAGE\\$base" >/dev/null 2>&1; exit $rc ;;
  get)
    shift; rel="$1"; dst="$2"; case "$rel" in *..*|/*) echo "chemin refuse" >&2; exit 98;; esac
    hostdir="$STAGE\\get-$tag"
    ctl pull -Path "$(printf '%s' "$rel" | tr '/' '\\')" -Dest "$hostdir\\" || exit 94
    mkdir -p "$dst" && "${SCP[@]}" -r "$HOST:$STAGE_FWD/get-$tag/." "$dst/"; rc=$?
    "${SSH[@]}" "rmdir /s /q $hostdir" >/dev/null 2>&1; exit $rc ;;
  *) sed -n '2,13p' "$0"; exit 2 ;;
esac
