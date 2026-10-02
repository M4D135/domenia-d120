#!/bin/bash
# Mac side: D120 integration campaign INSIDE the test VM (never on the host), through lab.sh and the relay socket.
#   campaign.sh run    [DEST]   sync this working tree to LAB_DIR (default d120int), run Invoke-D120Campaign.ps1, fetch, verify
#   campaign.sh base   [DEST]   run the reference commit (BASE_REF, default e0cb72a = VM baseline 1296/77) in LAB_DIR d120base
#   campaign.sh report RUN [BASE_SUITES]   verify binding and compare again (campaign_report.py)
# The result is an integration report: it never sets acceptance_passed (only release_guard.py --require-windows on the ZIP).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"
case "${1:-}" in
  run)
    export LAB_DIR="${LAB_DIR:-d120int}"
    DEST="${2:-$HOME/Downloads/Domenia-lab/runs/$LAB_DIR-$STAMP}"
    commit="$(git -C "$ROOT" rev-parse HEAD)" || exit 2
    dirty=""; [ -n "$(git -C "$ROOT" status --porcelain)" ] && dirty=" -SourceDirty"
    cmd='& .\engineering\d120\lab\Invoke-D120Campaign.ps1 -OutDir ..\out\campaign -SourceCommit '"$commit$dirty"
    "$HERE/lab.sh" status || exit $?
    "$HERE/lab.sh" sync || exit $?
    # Short checks first (one guest process, default 3600 s cap), then the suites with a longer cap.
    "$HERE/lab.sh" ps "$cmd -Steps env,compat,parser,startcheck"; rc1=$?
    LAB_TIMEOUT="${LAB_TIMEOUT:-10800}" "$HERE/lab.sh" ps "$cmd -Steps suites"; rc2=$?
    "$HERE/lab.sh" get out/campaign "$DEST" || { echo "rapatriement impossible (checks=$rc1 suites=$rc2)" >&2; exit 94; }
    echo "Resultats: $DEST (checks=$rc1 suites=$rc2)"
    python3 "$HERE/campaign_report.py" "$DEST" ${BASE_RUN:+--base-run "$BASE_RUN"} --out "$DEST/_verdict.json" ;;
  base)
    export LAB_DIR="${LAB_DIR:-d120base}"
    ref="${BASE_REF:-e0cb72a}"
    DEST="${2:-$HOME/Downloads/Domenia-lab/runs/$LAB_DIR-$STAMP}"
    tmp="$(mktemp -d)"; wt="$tmp/base"
    git -C "$ROOT" worktree add --detach "$wt" "$ref" >/dev/null || exit 2
    LAB="$wt/dev/engineering/d120/lab/lab.sh"
    "$LAB" sync; rc=$?
    if [ $rc -eq 0 ]; then
      "$LAB" ps '& .\engineering\d120\lab\Invoke-LabRun.ps1 -DevRoot . -OutDir ..\out\base'; rc=$?
      "$LAB" get out/base "$DEST" || rc=94
    fi
    git -C "$ROOT" worktree remove --force "$wt"; rm -rf "$tmp"
    echo "Reference $ref: $DEST (rc=$rc) ; comparer avec BASE_RUN=<dossier contenant les *.ps1.json> campaign.sh run"
    python3 "$HERE/compare_runs.py" "$(dirname "$(find "$DEST" -name _summary.json | head -1)")"
    exit $rc ;;
  report)
    shift; python3 "$HERE/campaign_report.py" "$1" ${2:+--base-run "$2"} ;;
  *) sed -n '2,6p' "$0"; exit 2 ;;
esac
