#!/usr/bin/env bash
# Refresh the vendored SDK conformance scenarios from a Fountain checkout.
#
#   Scripts/sync-conformance.sh [path-to-fountain-repo]
#
# The scenarios are Fountain's, shared by every language SDK, and are copied
# verbatim — never edited here. Whatever the copy changes, `swift test` is the
# arbiter: a new scenario has no verdict and fails `everyScenarioHasAVerdict`
# until someone rules on it in verdicts.json.
set -euo pipefail

repo="${1:-${FOUNTAIN_REPO:-$(cd "$(dirname "$0")/.." && pwd)/../../BinaryBourbon/fountain}}"
source_dir="$repo/sdk/conformance"
here="$(cd "$(dirname "$0")/.." && pwd)"
target="$here/Tests/FountainKitTests/Conformance"

if [ ! -d "$source_dir/scenarios" ]; then
  echo "No conformance suite at $source_dir" >&2
  echo "Pass the path to a Fountain checkout, or set FOUNTAIN_REPO." >&2
  exit 1
fi

before="$(ls "$target/scenarios" 2>/dev/null | sort || true)"

rm -rf "$target/scenarios"
mkdir -p "$target/scenarios"
cp "$source_dir"/scenarios/*.json "$target/scenarios/"
cp "$source_dir/README.md" "$target/SUITE.md"

commit="$(git -C "$repo" rev-parse --short HEAD)"
today="$(date +%Y-%m-%d)"
python3 - "$target/verdicts.json" "$commit" "$today" <<'PY'
import json, sys
path, commit, today = sys.argv[1:4]
with open(path) as handle:
    text = handle.read()
document = json.loads(text)
document["source"]["commit"] = commit
document["source"]["synced"] = today
with open(path, "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
PY

after="$(ls "$target/scenarios" | sort)"
added="$(comm -13 <(echo "$before") <(echo "$after") || true)"
removed="$(comm -23 <(echo "$before") <(echo "$after") || true)"

echo "Synced $(echo "$after" | wc -l | tr -d ' ') scenarios from $repo @ $commit"
[ -n "$added" ] && echo "New (need a verdict):" && echo "$added" | sed 's/^/  /'
[ -n "$removed" ] && echo "Gone (drop their verdicts):" && echo "$removed" | sed 's/^/  /'
echo "Now run: swift test --filter Conformance"
exit 0
