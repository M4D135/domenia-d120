#!/bin/bash
# Tests of the « e2e » command of tools/vm.sh and of the desktop-session path of « capture », in dry-run mode
# (DOMENIA_VM_DRY_RUN=1): nothing is sent to the VM. Written with the code, run at the very end with the other tests
# (decision of 21/10): bash tests/tools/vm-e2e-test.sh
set -uo pipefail

VM=$(cd "$(dirname "$0")/../../tools" && pwd)/vm.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/domenia-vm-e2e-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export DOMENIA_VM_LOCK="$WORK/lock"
export DOMENIA_VM_DRY_RUN=1
export DOMENIA_VM_LOCK_POLL=1
passed=0
failed=0

ok() { passed=$((passed + 1)); echo "OK    $1"; }
ko() { failed=$((failed + 1)); echo "ECHEC $1"; }

# expect_refused <name> <command...>: non-zero exit, nothing sent.
expect_refused() {
  local name=$1
  shift
  if "$@" >"$WORK/r.out" 2>&1; then ko "$name (admis à tort)"; elif grep -q '\[essai\] PowerShell' "$WORK/r.out"; then ko "$name (commande envoyée)"; else ok "$name"; fi
}

# 1. e2e: build Release, then e2e-vm.ps1 through desktop-run.ps1, copy into --out.
"$VM" lot-e2e e2e --scenarios 'accueil/*' --out "$WORK/out" --no-sync >"$WORK/a.out" 2>&1
code=$?
[ $code -eq 0 ] && ok "e2e en essai réussit" || ko "e2e en essai réussit ($code)"
grep -q "build-vm.ps1' -Configuration Release" "$WORK/a.out" && ok "e2e compile en Release par défaut" || ko "e2e compile en Release par défaut"
grep -q "desktop-run.ps1' -Script 'e2e-vm.ps1' -Session auto -TimeoutSeconds 3600" "$WORK/a.out" && ok "e2e passe par la session de bureau (auto)" || ko "e2e passe par desktop-run.ps1"
grep -q "Mode = 'simulation'; Configuration = 'Release'; Scenarios = 'accueil/\*'" "$WORK/a.out" && ok "e2e transmet mode, configuration et motif" || ko "arguments de e2e-vm.ps1"
grep -q "copie de C:\\\\DomeniaDev\\\\e2e\\\\lot-e2e vers $WORK/out" "$WORK/a.out" && ok "e2e rapatrie le rapport du lot" || ko "rapatriement du rapport"

# 2. Options of e2e.
"$VM" lot-e2e e2e --mode annuaire --config Debug --no-sync >"$WORK/b.out" 2>&1
grep -q "Debug\\\\net10.0-windows\\\\win-x64\\\\Domenia.exe'; Mode = 'annuaire'; Configuration = 'Debug'" "$WORK/b.out" && ok "mode annuaire et build Debug" || ko "mode annuaire et build Debug"
"$VM" lot-e2e e2e --pack --no-sync >"$WORK/c.out" 2>&1
grep -q "Release -Publish" "$WORK/c.out" && grep -q "out\\\\lot-e2e\\\\Domenia\\\\Domenia.exe" "$WORK/c.out" && ok "--pack publie puis pilote le pack du lot" || ko "--pack"
DOMENIA_VM_SESSION=direct DOMENIA_VM_E2E_TIMEOUT=900 "$VM" lot-e2e e2e --no-sync >"$WORK/d.out" 2>&1
grep -q "\-Session direct -TimeoutSeconds 900" "$WORK/d.out" && ok "DOMENIA_VM_SESSION et DOMENIA_VM_E2E_TIMEOUT transmis" || ko "variables de session et de délai"

# 3. Refusals: nothing reaches the VM.
expect_refused "motif avec point-virgule refusé" "$VM" lot-e2e e2e --scenarios 'a;rm -rf' --no-sync
expect_refused "motif avec espace refusé" "$VM" lot-e2e e2e --scenarios 'a b' --no-sync
expect_refused "mode inconnu refusé" "$VM" lot-e2e e2e --mode prod --no-sync
expect_refused "--scenarios hors e2e refusé" "$VM" lot-e2e capture --scenarios accueil --no-sync
expect_refused "--routes hors capture refusé" "$VM" lot-e2e e2e --routes accueil --no-sync
expect_refused "--pack avec Debug refusé" "$VM" lot-e2e e2e --pack --config Debug --no-sync
expect_refused "--out hors capture et e2e refusé" "$VM" lot-e2e build --out "$WORK/x" --no-sync
expect_refused "DOMENIA_VM_SESSION inconnue refusée" env DOMENIA_VM_SESSION=partout "$VM" lot-e2e e2e --no-sync
expect_refused "DOMENIA_VM_E2E_TIMEOUT trop court refusé" env DOMENIA_VM_E2E_TIMEOUT=5 "$VM" lot-e2e e2e --no-sync

# 4. capture goes through desktop-run.ps1 with a bound that grows with screens and themes.
"$VM" lot-e2e capture --routes accueil,parametres --themes dark,light --no-sync >"$WORK/e.out" 2>&1
grep -q "desktop-run.ps1' -Script 'capture-vm.ps1' -Session auto -TimeoutSeconds 990 -Arguments @{ Exe = '.*'; Clean = \$true; Routes = 'accueil,parametres'; Themes = 'dark,light' }" "$WORK/e.out" \
  && ok "capture passe par la session de bureau, délai 330 + 135 × 2 × 2 + 120 s" || ko "capture par desktop-run.ps1"

if [ ! -e "$DOMENIA_VM_LOCK" ] && [ ! -L "$DOMENIA_VM_LOCK" ]; then ok "verrou rendu à la fin"; else ko "verrou rendu à la fin"; fi
echo "Bilan : $passed réussi(s), $failed en échec."
[ $failed -eq 0 ]
