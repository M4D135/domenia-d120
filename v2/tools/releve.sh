#!/bin/bash
# Relève OpenCode de la vague 2 de Domenia 2 : chaque écran puis l'intégration, l'un après l'autre.
# Usage : MODEL=anthropic/<modèle> bash v2/tools/releve.sh [écran ...]
# Sans argument : tous les écrans dans l'ordre d'intégration, puis l'intégration.
set -u
: "${MODEL:?Indiquer le modèle OpenCode, par exemple MODEL=anthropic/<modèle>}"
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEAM="$ROOT/../Domenia-D120-team"
LOGS="$TEAM/_releve"; mkdir -p "$LOGS"
PAGES=${*:-"shell accueil rechercher fiche comptes relations poste assistance requetes audit schema synchro operations parametres"}
git -C "$ROOT" fetch -q origin
for id in $PAGES; do
  wt="$TEAM/v2-$id"
  if [ ! -d "$wt" ]; then git -C "$ROOT" worktree add -q "$wt" "v2-page/$id" 2>/dev/null || git -C "$ROOT" worktree add -q -b "v2-page/$id" "$wt" "origin/v2-page/$id"; fi
  git -C "$wt" pull -q --ff-only origin "v2-page/$id" 2>/dev/null
  echo "$(date '+%d/%m %H:%M') écran $id : début" | tee -a "$LOGS/releve.log"
  prompt=$(sed "s/__ID__/$id/g" "$ROOT/v2/docs/reprise/PROMPT-ECRAN.md")
  ( cd "$wt" && opencode run --auto -m "$MODEL" "$prompt" ) > "$LOGS/$id.log" 2>&1
  echo "$(date '+%d/%m %H:%M') écran $id : fin (code $?), dernier commit $(git -C "$wt" log -1 --format='%h %s' | cut -c1-80)" | tee -a "$LOGS/releve.log"
done
if [ $# -eq 0 ]; then
  echo "$(date '+%d/%m %H:%M') intégration : début" | tee -a "$LOGS/releve.log"
  ( cd "$ROOT" && git checkout -q v2 && git pull -q --ff-only origin v2 && opencode run --auto -m "$MODEL" "$(cat v2/docs/reprise/PROMPT-INTEGRATION.md)" ) > "$LOGS/integration.log" 2>&1
  echo "$(date '+%d/%m %H:%M') intégration : fin (code $?)" | tee -a "$LOGS/releve.log"
fi
