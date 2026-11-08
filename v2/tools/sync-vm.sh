#!/bin/bash
# Mirrors the v2/ tree that holds this script (a worktree works too) into the Domenia VM, without bin/obj.
#   sync-vm.sh <lot>   -> C:\DomeniaDev\src\<lot>\v2   (one folder per batch of the team: builds never collide)
#   sync-vm.sh         -> C:\DomeniaDev\src\v2         (historical folder)
#   sync-vm.sh cache   -> pushes the NuGet packs and the WebView2 runtime once
# The VM copy is an exact mirror (files deleted or renamed on the Mac disappear from the VM), except the build outputs
# (bin, obj, .vs) and Domenia.sln, which stay so incremental builds keep working. Prefer tools/vm.sh, which takes the
# exclusive VM lock before calling this script.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
HOST=${DOMENIA_VM_HOST:-domenia-vm}
LOT=${1:-}
if [ "$LOT" = "cache" ]; then
  C=/Users/david/Documents/Projets/Domenia-D120-cache
  ssh "$HOST" "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path C:\\DomeniaDev\\cache\\nuget,C:\\DomeniaDev\\cache\\webview2 | Out-Null\""
  COPYFILE_DISABLE=1 tar -C "$C/nuget" --exclude="._*" -cf - . | ssh "$HOST" "tar -xf - -C C:/DomeniaDev/cache/nuget"
  ssh "$HOST" "powershell -NoProfile -Command \"if(-not (Test-Path C:\\DomeniaDev\\cache\\webview2\\runtime)){New-Item -ItemType Directory -Path C:\\DomeniaDev\\cache\\webview2 -Force|Out-Null; Copy-Item -Recurse C:\\DomeniaLab\\WebView\\runtime C:\\DomeniaDev\\cache\\webview2\\runtime}; 'cache ok'\""
  exit 0
fi
if [ -n "$LOT" ]; then
  # Lot names end up in Windows paths and remote commands: a strict form only.
  if ! [[ "$LOT" =~ ^[a-z0-9][a-z0-9-]{0,39}$ ]]; then
    echo "Lot invalide : minuscules, chiffres et tirets, 40 caractères au plus (par exemple accueil ou plateforme)." >&2
    exit 64
  fi
  # « v2 » and « domenia » would mix with the historical folders (C:\DomeniaDev\src\v2, C:\DomeniaDev\out\Domenia).
  case "$LOT" in
    v2|domenia) echo "Lot réservé : $LOT (dossiers historiques de la VM)." >&2; exit 64 ;;
  esac
  BASE="C:/DomeniaDev/src/$LOT"
else
  BASE="C:/DomeniaDev/src"
fi
DEST="$BASE/v2"
STAGE="$BASE/v2.sync"
WIN_DEST=${DEST//\//\\}
WIN_STAGE=${STAGE//\//\\}
ssh "$HOST" "powershell -NoProfile -Command \"\$ErrorActionPreference='Stop'; if (Test-Path '$WIN_STAGE') { Remove-Item -Recurse -Force '$WIN_STAGE' }; New-Item -ItemType Directory -Force -Path '$WIN_STAGE','$WIN_DEST' | Out-Null\""
COPYFILE_DISABLE=1 tar -C "$R" --exclude='._*' --exclude='.DS_Store' --exclude='bin' --exclude='obj' --exclude='.vs' \
  --exclude='docs/catalogue-source/prompts' -cf - . | ssh "$HOST" "tar -xf - -C $STAGE"
# robocopy /MIR: copies what changed (timestamps kept), deletes what no longer exists; excluded names are neither copied
# nor deleted. Exit codes 0 to 7 are successes.
ssh "$HOST" "powershell -NoProfile -Command \"robocopy '$WIN_STAGE' '$WIN_DEST' /MIR /XD bin obj .vs /XF Domenia.sln /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null; \$code = \$LASTEXITCODE; Remove-Item -Recurse -Force '$WIN_STAGE'; if (\$code -ge 8) { Write-Output ('robocopy : code ' + \$code); exit 1 }\""
echo "sync ok -> $WIN_DEST"
