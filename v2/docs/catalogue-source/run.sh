#!/bin/bash
# Run every catalogue prompt on the Spark, 3 at a time, skipping finished ones.
O=/Users/david/Documents/Projets/Domenia-D120/v2/docs/catalogue-source
n=0
for f in $O/prompts/*.txt; do
  b=$(basename $f .txt); [ -s $O/$b.md ] && continue
  ( ~/bin/kbza ask --prompt-file $f --no-memory --max-tokens 0 > $O/$b.md.tmp 2> $O/$b.err && mv $O/$b.md.tmp $O/$b.md; echo "$(date +%H:%M) $b $(wc -l < $O/$b.md 2>/dev/null)" >> $O/run.log ) &
  n=$((n+1)); if [ $((n % 3)) -eq 0 ]; then wait; fi
done; wait; echo "FIN $(ls $O/*.md | wc -l)" >> $O/run.log
