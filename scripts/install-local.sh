#!/usr/bin/env bash
# Installs build/Foliarium.app into /Applications and opens it.
set -euo pipefail

cd "$(dirname "$0")/.."
[[ -d build/Foliarium.app ]] || { echo "Run scripts/build-app.sh first" >&2; exit 1; }

osascript -e 'quit app "Foliarium"' 2>/dev/null || true
sleep 1
rm -rf /Applications/Foliarium.app
ditto build/Foliarium.app /Applications/Foliarium.app
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Keep only the installed copy registered, so Open at Login and Spotlight find that one.
"$LSREGISTER" -dump | sed -nE 's/^path: +(.*Foliarium\.app) \(0x[0-9a-f]+\)$/\1/p' | sort -u | while IFS= read -r copy; do
    [[ "$copy" == "$PWD/build/"* ]] && "$LSREGISTER" -u "$copy" 2>/dev/null || true
done
"$LSREGISTER" -f /Applications/Foliarium.app
open /Applications/Foliarium.app
echo "Installed and opened /Applications/Foliarium.app"
