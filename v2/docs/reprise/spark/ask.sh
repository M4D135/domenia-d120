#!/bin/bash
# Builds the full prompt of a Spark task (common rules + task + context files) and asks the Spark; output in <task>.out.
L=/private/var/folders/xc/v6v5dly119l9sy64nyj2460m0000gn/T/opencode
R=/Users/david/Documents/Projets/Domenia-D120
t=$1
p="$L/spark/$t.full.md"
{
  cat "$L/spark/common.md"; echo; echo "# Tâche"; echo; cat "$L/spark/$t.md"; echo
  if [ -f "$L/spark/$t.files" ]; then
    echo "# Fichiers de contexte (lecture seule)"; echo
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      if [[ "$f" = /* ]]; then src="$f"; else src="$R/$f"; fi
      echo "=== CONTEXT: ${f#/private/var/folders/xc/v6v5dly119l9sy64nyj2460m0000gn/T/opencode/spark/}  ==="; cat "$src"; echo "=== END CONTEXT ==="; echo
    done < "$L/spark/$t.files"
  fi
} > "$p"
echo "prompt: $(wc -c < "$p") octets"
~/bin/kbza ask --no-memory --prompt-file "$p" --max-tokens 0 > "$L/spark/$t.out" 2> "$L/spark/$t.err"
echo "rc=$? out=$(wc -c < "$L/spark/$t.out") octets"
