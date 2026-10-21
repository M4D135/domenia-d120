#!/bin/bash
# Sync v2/ sources to the Domenia VM (C:\DomeniaDev\src\v2) without bin/obj; optional "cache" pushes packs and runtime once.
set -e
R=$(cd "$(dirname "$0")/.." && pwd)
if [ "${1:-}" = "cache" ]; then
  C=/Users/david/Documents/Projets/Domenia-D120-cache
  ssh domenia-vm "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path C:\\DomeniaDev\\cache\\nuget,C:\\DomeniaDev\\cache\\webview2 | Out-Null\""
  COPYFILE_DISABLE=1 tar -C "$C/nuget" --exclude="._*" -cf - . | ssh domenia-vm "tar -xf - -C C:/DomeniaDev/cache/nuget"
  ssh domenia-vm "powershell -NoProfile -Command \"if(-not (Test-Path C:\\DomeniaDev\\cache\\webview2\\runtime)){New-Item -ItemType Directory -Path C:\\DomeniaDev\\cache\\webview2 -Force|Out-Null; Copy-Item -Recurse C:\\DomeniaLab\\WebView\\runtime C:\\DomeniaDev\\cache\\webview2\\runtime}; 'cache ok'\""
  exit 0
fi
ssh domenia-vm "powershell -NoProfile -Command \"New-Item -ItemType Directory -Force -Path C:\\DomeniaDev\\src\\v2 | Out-Null\""
COPYFILE_DISABLE=1 tar -C "$R" --exclude='._*' --exclude='.DS_Store' --exclude='bin' --exclude='obj' --exclude='.vs' --exclude='docs/catalogue-source/prompts' -cf - . | ssh domenia-vm "tar -xf - -C C:/DomeniaDev/src/v2"
echo "sync ok"
