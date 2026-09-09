#!/usr/bin/env bash
set -euo pipefail

# GITHUB_ACTION_PATH is unset when the script is called directly instead of as the action.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

PACKAGES=(
  "semantic-release"
  "@semantic-release/commit-analyzer"
  "@semantic-release/release-notes-generator"
  "@semantic-release/git"
  "@semantic-release/github"
  "@semantic-release/exec"
  "semantic-release-export-data"
  # 10.x targets conventional-changelog-writer 9, release-notes-generator 14 pins
  # writer 8, and the mismatch silently drops every commit section.
  "conventional-changelog-conventionalcommits@^9"
)

[ "${INPUT_ENABLE_MONOREPO}" = "true" ] && PACKAGES+=("semantic-release-monorepo")

if [ -n "${INPUT_EXTRA_PLUGINS}" ]; then
  while IFS= read -r line || [ -n "${line}" ]; do
    for pkg in ${line}; do
      pkg="$(echo "${pkg}" | xargs)"
      [ -n "${pkg}" ] && PACKAGES+=("${pkg}")
    done
  done <<< "${INPUT_EXTRA_PLUGINS}"
fi

# Own install directory instead of npx: the plugins then resolve their presets next
# to themselves and never reach for whatever the released project happens to have.
TOOLS_DIR="${RUNNER_TEMP:-/tmp}/semantic-release-tools"
mkdir -p "${TOOLS_DIR}"
npm install --prefix "${TOOLS_DIR}" --no-save --no-audit --no-fund --loglevel error "${PACKAGES[@]}"

node "${SCRIPT_DIR}/verify-preset.mjs" "${TOOLS_DIR}"

SEMANTIC_RELEASE="${TOOLS_DIR}/node_modules/.bin/semantic-release"

# npx populated npm_package_* from the package.json in CWD; calling the binary
# directly does not, and release configs interpolate those variables.
export_npm_package_env() {
  [ -f package.json ] || return 0

  local name version
  {
    IFS= read -r name
    IFS= read -r version
  } < <(node -e 'const p = require("./package.json"); console.log(p.name ?? ""); console.log(p.version ?? "")')

  [ -n "${name}" ] || echo "::warning::package.json in $(pwd) has no name — configs reading npm_package_name see an empty value"
  export npm_package_name="${name}"
  export npm_package_version="${version}"
}

SR_ARGS=()
if [ "${INPUT_DRY_RUN}" = "true" ]; then
  SR_ARGS+=("--dry-run")
  echo "::warning::Dry-run mode active — no release will be published"
fi

# semantic-release-monorepo reads package.json for the tag prefix; removed after the run so
# helm package does not ship it inside the chart archive.
provide_package_json() {
  [ -f package.json ] && return 1
  [ -f Chart.yaml ] || { echo "::error::${PWD} has neither package.json nor Chart.yaml"; return 2; }

  local name
  name=$(sed -n 's/^name:[[:space:]]*//p' Chart.yaml | head -1 | tr -d "\"'" | xargs)
  if [ -z "${name}" ]; then
    echo "::error::Chart.yaml in ${PWD} has no name"
    return 2
  fi

  printf '{"name":"%s","version":"0.0.0","private":true}\n' "${name}" > package.json
  echo "Generated package.json for chart ${name}"
  return 0
}

release_module() {
  local status=0
  provide_package_json || status=$?
  case "${status}" in
    0) trap 'rm -f package.json' EXIT ;;
    2) return 1 ;;
  esac

  export_npm_package_env
  "${SEMANTIC_RELEASE}" -e semantic-release-monorepo "${SR_ARGS[@]}"
}

if [ "${INPUT_ENABLE_MONOREPO}" = "true" ]; then
  MODULE_DIRS=$(find . -maxdepth 2 -type f \( -name "package.json" -o -name "Chart.yaml" \) \
    ! -path "./package.json" \
    ! -path "./Chart.yaml" \
    ! -path "*/node_modules/*" \
    -exec dirname {} \; | sed 's|^./||' | sort -u)

  if [ -z "${MODULE_DIRS}" ]; then
    echo "::error::Monorepo mode is active but no modules with a package.json or Chart.yaml were found"
    exit 1
  fi

  echo "::notice::Processing modules: ${MODULE_DIRS}"
  HAS_FAILURE=0

  for dir in ${MODULE_DIRS}; do
    if [ -d "${dir}" ]; then
      echo "::group::Module: ${dir}"
      (cd "${dir}" && release_module) || HAS_FAILURE=1
      echo "::endgroup::"
    fi
  done

  if [ "${HAS_FAILURE}" -ne 0 ]; then
    echo "::error::Release failed for one or more modules"
    exit 1
  fi

  echo "new_release_published=true" >> "$GITHUB_OUTPUT"
else
  export_npm_package_env
  "${SEMANTIC_RELEASE}" "${SR_ARGS[@]}"
  echo "new_release_published=${new_release_published:-false}" >> "$GITHUB_OUTPUT"
fi
