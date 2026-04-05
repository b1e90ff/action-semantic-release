#!/usr/bin/env bash
set -euo pipefail

: "${NPM_TOKEN:?NPM_TOKEN is required}"
: "${NPM_SCOPE:?NPM_SCOPE is required}"
: "${NPM_REGISTRY:?NPM_REGISTRY is required}"

host="${NPM_REGISTRY#https://}"

cat > .npmrc <<EOF
//${host}/:_authToken=${NPM_TOKEN}
${NPM_SCOPE}:registry=${NPM_REGISTRY}
EOF
