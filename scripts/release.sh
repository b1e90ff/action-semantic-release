#!/usr/bin/env bash
set -euo pipefail

PACKAGES=(
  "semantic-release"
  "@semantic-release/commit-analyzer"
  "@semantic-release/release-notes-generator"
  "@semantic-release/git"
  "@semantic-release/github"
  "@semantic-release/exec"
  "semantic-release-export-data"
  "conventional-changelog-conventionalcommits"
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

NPX_ARGS=()
for pkg in "${PACKAGES[@]}"; do
  NPX_ARGS+=("-p" "${pkg}")
done

SR_ARGS=()
if [ "${INPUT_DRY_RUN}" = "true" ]; then
  SR_ARGS+=("--dry-run")
  echo "::warning::Dry-run mode active — no release will be published"
fi

if [ "${INPUT_ENABLE_MONOREPO}" = "true" ]; then
  MODULE_DIRS=$(find . -maxdepth 2 -type f -name "package.json" \
    ! -path "./package.json" \
    ! -path "*/node_modules/*" \
    -exec dirname {} \; | sed 's|^./||' | sort)

  if [ -z "${MODULE_DIRS}" ]; then
    echo "::error::Monorepo mode is active but no modules with package.json were found"
    exit 1
  fi

  echo "::notice::Processing modules: ${MODULE_DIRS}"
  HAS_FAILURE=0

  for dir in ${MODULE_DIRS}; do
    if [ -d "${dir}" ]; then
      echo "::group::Module: ${dir}"
      (cd "${dir}" && npx "${NPX_ARGS[@]}" semantic-release -e semantic-release-monorepo "${SR_ARGS[@]}") || HAS_FAILURE=1
      echo "::endgroup::"
    fi
  done

  if [ "${HAS_FAILURE}" -ne 0 ]; then
    echo "::error::Release failed for one or more modules"
    exit 1
  fi

  echo "new_release_published=true" >> "$GITHUB_OUTPUT"
else
  npx "${NPX_ARGS[@]}" semantic-release "${SR_ARGS[@]}"
  echo "new_release_published=${new_release_published:-false}" >> "$GITHUB_OUTPUT"
fi
