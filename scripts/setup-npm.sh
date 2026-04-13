#!/usr/bin/env bash
set -euo pipefail

: "${NPM_TOKEN:?NPM_TOKEN is required}"
: "${NPM_SCOPE:?NPM_SCOPE is required}"
: "${NPM_REGISTRY:?NPM_REGISTRY is required}"

host="${NPM_REGISTRY#https://}"

# Write to $HOME so per-module subdirectory runs (monorepo mode)
# also see the registry mapping and auth token. npm reads .npmrc
# from CWD/$HOME/global and does not walk up parent directories,
# so a project-level .npmrc in the workspace root would be invisible
# to "cd module && npx ..." invocations.
cat > "${HOME}/.npmrc" <<EOF
//${host}/:_authToken=${NPM_TOKEN}
${NPM_SCOPE}:registry=${NPM_REGISTRY}
EOF
