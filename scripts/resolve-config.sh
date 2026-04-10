#!/usr/bin/env bash
set -euo pipefail

KNOWN_CONFIGS=(
  .releaserc
  .releaserc.js
  .releaserc.cjs
  .releaserc.json
  .releaserc.yml
  .releaserc.yaml
  release.config.js
  release.config.cjs
)

for cfg in "${KNOWN_CONFIGS[@]}"; do
  if [ -f "${cfg}" ]; then
    echo "::notice::Project release configuration found: ${cfg}"
    exit 0
  fi
done

cp "${GITHUB_ACTION_PATH}/.releaserc.cjs" ./
echo "::notice::Default release configuration applied"
