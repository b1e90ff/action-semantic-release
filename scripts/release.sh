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

SR_LOG=""
trap 'rm -f "${SR_LOG:-}"' EXIT

if [ -z "${SEMANTIC_RELEASE:-}" ]; then
  # Own install directory instead of npx: the plugins then resolve their presets next
  # to themselves and never reach for whatever the released project happens to have.
  TOOLS_DIR="${RUNNER_TEMP:-/tmp}/semantic-release-tools"
  mkdir -p "${TOOLS_DIR}"
  npm install --prefix "${TOOLS_DIR}" --no-save --no-audit --no-fund --loglevel error "${PACKAGES[@]}"

  node "${SCRIPT_DIR}/verify-preset.mjs" "${TOOLS_DIR}"

  SEMANTIC_RELEASE="${TOOLS_DIR}/node_modules/.bin/semantic-release"
fi

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

  if [ "${INPUT_GENERATE_PACKAGE_JSON}" != "true" ]; then
    echo "::error::${PWD} has no package.json and generate-package-json is off"
    return 2
  fi

  [ -f Chart.yaml ] || { echo "::error::${PWD} has neither package.json nor Chart.yaml"; return 2; }

  local name
  name=$(sed -n 's/^name:[[:space:]]*//p' Chart.yaml | head -1 | tr -d '\r' | tr -d "\"'" | xargs)
  # A stray control character from a CRLF Chart.yaml would produce unparsable JSON below.
  if [[ ! "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "::error::Chart.yaml in ${PWD} has no usable name"
    return 2
  fi

  printf '{"name":"%s","version":"0.0.0","private":true}\n' "${name}" > package.json
  echo "Generated package.json for chart ${name}"
  return 0
}

# semantic-release reads its configuration from the working directory, one per module.
provide_release_config() {
  local cfg="${RELEASE_CONFIG_FILE:-}"
  [ -z "${cfg}" ] && return 0
  [ -f "${cfg}" ] && return 0
  [ -f "${REPO_ROOT}/${cfg}" ] || { echo "::error::${cfg} is missing at the repository root"; return 1; }
  cp "${REPO_ROOT}/${cfg}" ./
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
  : "${INPUT_MODULE_MARKERS:?module-markers must not be empty}"
  : "${INPUT_GENERATE_PACKAGE_JSON:?generate-package-json must be true or false}"

  : "${INPUT_MODULE_PATTERN:?module-pattern must not be empty}"

  MARKERS=()
  IFS=',' read -r -a raw_markers <<< "${INPUT_MODULE_MARKERS}"
  for entry in "${raw_markers[@]}"; do
    read -r marker <<< "${entry}"
    [ -n "${marker}" ] && MARKERS+=("${marker}")
  done

  if [ ${#MARKERS[@]} -eq 0 ]; then
    echo "::error::module-markers is empty, so no module can be discovered"
    exit 1
  fi

  MODULE_DIRS=()
  declare -A module_seen=()
  shopt -s nullglob
  for candidate in ${INPUT_MODULE_PATTERN}; do
    candidate="${candidate%/}"
    [ -d "${candidate}" ] || continue
    case "${candidate}" in */node_modules|*/node_modules/*|node_modules|.*) continue ;; esac
    [ -n "${module_seen[${candidate}]:-}" ] && continue
    for marker in "${MARKERS[@]}"; do
      if [ -f "${candidate}/${marker}" ]; then
        module_seen["${candidate}"]=1
        MODULE_DIRS+=("${candidate}")
        break
      fi
    done
  done
  shopt -u nullglob

  if [ ${#MODULE_DIRS[@]} -eq 0 ]; then
    echo "::error::No directory under '${INPUT_MODULE_PATTERN}' carries one of: ${INPUT_MODULE_MARKERS}"
    exit 1
  fi

  echo "::notice::Processing modules: ${MODULE_DIRS[*]}"
  REPO_ROOT="${PWD}"
  HAS_FAILURE=0

  for dir in "${MODULE_DIRS[@]}"; do
    echo "::group::Module: ${dir}"
    (cd "${dir}" && provide_release_config && release_module) || HAS_FAILURE=1
    echo "::endgroup::"
  done

  if [ "${HAS_FAILURE}" -ne 0 ]; then
    echo "::error::Release failed for one or more modules"
    exit 1
  fi

  echo "new_release_published=true" >> "$GITHUB_OUTPUT"
else
  export_npm_package_env

  MAX_ATTEMPTS=1
  if [ "${INPUT_RETRY_ON_REMOTE_AHEAD:-true}" = "true" ]; then
    MAX_ATTEMPTS=3
  fi

  ATTEMPT=1
  TARGET_BRANCH="${GITHUB_REF_NAME:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"
  if [ -z "${TARGET_BRANCH}" ] || [ "${TARGET_BRANCH}" = "HEAD" ]; then
    TARGET_BRANCH="${DEFAULT_BRANCH:-main}"
  fi
  TARGET_BRANCH="${TARGET_BRANCH#refs/heads/}"

  is_release_published() {
    [ -n "${GITHUB_ENV:-}" ] && [ -f "${GITHUB_ENV}" ] && grep -q "^new_release_published=true$" "${GITHUB_ENV}"
  }

  while [ "${ATTEMPT}" -le "${MAX_ATTEMPTS}" ]; do
    if [ "${ATTEMPT}" -gt 1 ]; then
      echo "::notice::Retrying semantic-release (attempt ${ATTEMPT} of ${MAX_ATTEMPTS})..."
    fi

    git fetch origin "${TARGET_BRANCH}"

    if git rev-parse --verify "origin/${TARGET_BRANCH}" >/dev/null 2>&1; then
      LOCAL_SHA=$(git rev-parse HEAD 2>/dev/null || echo "")
      REMOTE_SHA=$(git rev-parse "origin/${TARGET_BRANCH}" 2>/dev/null || echo "")
      if [ -n "${LOCAL_SHA}" ] && [ -n "${REMOTE_SHA}" ] && [ "${LOCAL_SHA}" != "${REMOTE_SHA}" ]; then
        echo "Local HEAD differs from origin/${TARGET_BRANCH}. Synchronizing..."
        if ! git merge --ff-only "origin/${TARGET_BRANCH}"; then
          echo "::error::Cannot fast-forward to origin/${TARGET_BRANCH}. Branch has diverged or merge conflict detected." >&2
          exit 1
        fi
      fi
    fi

    SR_LOG=$(mktemp)
    set +e
    "${SEMANTIC_RELEASE}" ${SR_ARGS[@]+"${SR_ARGS[@]}"} 2>&1 | tee "${SR_LOG}"
    SR_STATUS=${PIPESTATUS[0]}
    set -e

    if [ "${SR_STATUS}" -ne 0 ]; then
      exit "${SR_STATUS}"
    fi

    if is_release_published; then
      new_release_published="true"
      break
    fi

    if grep -q "is behind the remote one" "${SR_LOG}"; then
      echo "::warning::semantic-release reported local branch is behind remote."
      if [ "${ATTEMPT}" -lt "${MAX_ATTEMPTS}" ]; then
        echo "Resetting local branch state to origin/${TARGET_BRANCH}..."
        git reset --hard "origin/${TARGET_BRANCH}" 2>/dev/null || true
        git clean -fd 2>/dev/null || true
        git tag -l | while IFS= read -r tag; do
          if [ -n "${tag}" ] && ! git ls-remote --exit-code --tags origin "refs/tags/${tag}" >/dev/null 2>&1; then
            git tag -d "${tag}" >/dev/null 2>&1 || true
          fi
        done
        echo "Fetching origin/${TARGET_BRANCH} and waiting $((5 * ATTEMPT)) seconds before retrying..."
        sleep $((5 * ATTEMPT))
        ATTEMPT=$((ATTEMPT + 1))
        continue
      fi
    fi

    break
  done

  echo "new_release_published=${new_release_published:-false}" >> "$GITHUB_OUTPUT"
fi
