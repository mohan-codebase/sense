#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
python3 - "$WORK/main.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path('src/main.swift').read_text().split('let app = NSApplication.shared\n')[0]
Path(sys.argv[1]).write_text(source + '\n' + Path('tools/feature_checks.swift').read_text())
PYTHON
swiftc -module-cache-path /tmp/sense-module-cache src/Preferences.swift src/SenseMark.swift "$WORK/main.swift" -o "$WORK/SenseFeatureChecks"
"$WORK/SenseFeatureChecks"
