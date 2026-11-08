#!/bin/bash
# Tests of the exclusive VM lock of tools/vm.sh, in dry-run mode (DOMENIA_VM_DRY_RUN=1): nothing is sent to the VM.
# Written with the code, run at the very end with the other tests (decision of 21/10): bash tests/tools/vm-lock-test.sh
set -uo pipefail

VM=$(cd "$(dirname "$0")/../../tools" && pwd)/vm.sh
WORK=$(mktemp -d "${TMPDIR:-/tmp}/domenia-vm-lock-test.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
export DOMENIA_VM_LOCK="$WORK/lock"
export DOMENIA_VM_DRY_RUN=1
export DOMENIA_VM_LOCK_POLL=1
passed=0
failed=0

ok() {
  passed=$((passed + 1))
  echo "OK    $1"
}

ko() {
  failed=$((failed + 1))
  echo "ECHEC $1"
}

# 1. Two batches started together run one after the other, never together.
DOMENIA_VM_DRY_RUN_HOLD=3 "$VM" lot-a build >"$WORK/a.out" 2>&1 &
first=$!
sleep 1
DOMENIA_VM_DRY_RUN_HOLD=3 "$VM" lot-b build >"$WORK/b.out" 2>&1 &
second=$!
wait "$first"; code_a=$?
wait "$second"; code_b=$?
if [ $code_a -eq 0 ] && [ $code_b -eq 0 ]; then ok "deux lots réussissent"; else ko "deux lots réussissent ($code_a, $code_b)"; fi
if grep -q "VM occupée (.* lot-a build)" "$WORK/b.out"; then ok "le second lot attend le premier et dit pourquoi"; else ko "le second lot attend le premier"; fi
if grep -q 'C:\\DomeniaDev\\src\\lot-b\\v2\\tools\\build-vm.ps1' "$WORK/b.out"; then ok "chaque lot compile dans son dossier"; else ko "dossier du lot"; fi
if [ ! -e "$DOMENIA_VM_LOCK" ] && [ ! -L "$DOMENIA_VM_LOCK" ]; then ok "verrou rendu à la fin"; else ko "verrou rendu à la fin"; fi

# 2. A lock left by a process that no longer exists is removed (current link form, then the folder of earlier versions).
ln -s "999999 $(hostname -s) $(date +%s) ancien build" "$DOMENIA_VM_LOCK"
if "$VM" lot-c build >"$WORK/c.out" 2>&1 && grep -q "verrou mort retiré" "$WORK/c.out"; then ok "verrou mort retiré"; else ko "verrou mort retiré"; fi
mkdir "$DOMENIA_VM_LOCK"
echo "999999 $(hostname -s) 0 ancien build" >"$DOMENIA_VM_LOCK/owner"
if "$VM" lot-c build >"$WORK/c2.out" 2>&1 && grep -q "verrou mort retiré" "$WORK/c2.out"; then ok "ancien verrou (dossier) mort retiré"; else ko "ancien verrou (dossier) mort retiré"; fi
if [ ! -e "$DOMENIA_VM_LOCK" ] && [ ! -L "$DOMENIA_VM_LOCK" ] && [ ! -L "$DOMENIA_VM_LOCK.takeover" ]; then ok "verrous rendus après reprise"; else ko "verrous rendus après reprise"; fi

# 3. A live owner is never dispossessed: the wait ends with an error and the lock stays.
live="$$ $(hostname -s) $(date +%s) vivant build"
ln -s "$live" "$DOMENIA_VM_LOCK"
DOMENIA_VM_LOCK_WAIT=3 "$VM" lot-d build >"$WORK/d.out" 2>&1
code=$?
if [ $code -ne 0 ] && grep -q "VM occupée depuis plus de 3 s" "$WORK/d.out" && [ "$(readlink "$DOMENIA_VM_LOCK")" = "$live" ]; then ok "propriétaire vivant respecté"; else ko "propriétaire vivant respecté ($code)"; fi
rm -f "$DOMENIA_VM_LOCK"

# 3b. Several waiters see the same dead lock: one removes it, then they run one after the other, never together.
ln -s "999999 $(hostname -s) $(date +%s) mort build" "$DOMENIA_VM_LOCK"
begin=$(date +%s)
pids=()
for n in 1 2 3; do
  DOMENIA_VM_DRY_RUN_HOLD=2 "$VM" "lot-r$n" build >"$WORK/r$n.out" 2>&1 &
  pids+=($!)
done
codes=0
for pid in "${pids[@]}"; do wait "$pid" || codes=$((codes + 1)); done
elapsed=$(( $(date +%s) - begin ))
removals=$(cat "$WORK"/r?.out | grep -c "verrou mort retiré")
if [ $codes -eq 0 ] && [ "$removals" -eq 1 ] && [ $elapsed -ge 6 ]; then ok "reprise concurrente d’un verrou mort : un seul retrait, lots en série"; else ko "reprise concurrente ($codes échec(s), $removals retrait(s), $elapsed s)"; fi

# 3c. Lock folder absent: refused at once, never a busy loop.
begin=$(date +%s)
DOMENIA_VM_LOCK="$WORK/absent/lock" DOMENIA_VM_LOCK_WAIT=2 "$VM" lot-g build >"$WORK/g.out" 2>&1
code=$?
if [ $code -ne 0 ] && grep -q "dossier du verrou absent" "$WORK/g.out" && [ $(( $(date +%s) - begin )) -le 3 ]; then ok "dossier du verrou absent : refus immédiat"; else ko "dossier du verrou absent ($code)"; fi

# 4. Invalid lots and options are refused before taking the lock.
"$VM" "Lot A" build >/dev/null 2>&1; code=$?
if [ $code -eq 64 ] && [ ! -d "$DOMENIA_VM_LOCK" ]; then ok "lot invalide refusé"; else ko "lot invalide refusé ($code)"; fi
for reserved in cache v2 domenia; do
  "$VM" "$reserved" build >/dev/null 2>&1; code=$?
  if [ $code -eq 64 ]; then ok "nom réservé refusé : $reserved"; else ko "nom réservé refusé : $reserved ($code)"; fi
done
"$VM" lot-e capture --routes 'accueil rechercher' >/dev/null 2>&1; code=$?
if [ $code -ne 0 ] && [ ! -d "$DOMENIA_VM_LOCK" ]; then ok "écrans invalides refusés"; else ko "écrans invalides refusés ($code)"; fi
"$VM" lot-e build --routes accueil >/dev/null 2>&1; code=$?
if [ $code -ne 0 ]; then ok "options de capture refusées hors capture"; else ko "options de capture hors capture"; fi

# 5. Capture: build Release, then the capture script with the routes and themes as PowerShell literals.
"$VM" lot-f capture --routes 'accueil,rechercher?q=a%20b' --themes dark,contrast --out "$WORK/images" >"$WORK/f.out" 2>&1
if grep -q "build-vm.ps1' -Configuration Release" "$WORK/f.out" \
  && grep -q "capture-vm.ps1' -Exe '.*' -Clean -Routes 'accueil,rechercher?q=a%20b' -Themes 'dark,contrast'" "$WORK/f.out"; then
  ok "capture : compilation puis capture du lot"
else
  ko "capture : commandes du lot"
fi

echo "$passed réussis, $failed en échec."
[ $failed -eq 0 ]
