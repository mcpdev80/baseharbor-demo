#!/usr/bin/env bash
set -euo pipefail
results="${1:?results.tsv required}"
version="${BASEHARBOR_VERSION:-unknown}"
artifact_dir="$(dirname "$results")"

printf '\nBaseHarbor %s Acceptance\n\n' "$version"
while IFS=$'\t' read -r name status detail; do
  printf '%-28s %s\n' "$name" "$status"
done < "$results"

if awk -F '\t' '$2=="FAIL"{found=1} END{exit !found}' "$results"; then
  overall=FAIL
else
  overall=PASS
fi
printf '\n%-28s %s\n' RESULT "$overall"

jq -Rn   --arg version "$version"   --arg result "$overall"   '[inputs | split("\t") | {name:.[0], status:.[1], detail:(.[2] // "")}] | {baseharbor_version:$version,result:$result,checks:.}'   < "$results" > "$artifact_dir/acceptance.json"

test "$overall" = PASS
