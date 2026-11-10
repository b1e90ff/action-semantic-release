#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SCRIPT="${SCRIPT_DIR}/../scripts/release.sh"
RESOLVE_SCRIPT="${SCRIPT_DIR}/../scripts/resolve-config.sh"
TEMP_ROOT=$(mktemp -d)
trap 'rm -rf "${TEMP_ROOT}"' EXIT

setup_repo() {
  local dir="$1"
  mkdir -p "${dir}/remote"
  git -C "${dir}/remote" init --bare --initial-branch=main >/dev/null 2>&1

  git clone "${dir}/remote" "${dir}/local" >/dev/null 2>&1
  git -C "${dir}/local" config user.name "tester"
  git -C "${dir}/local" config user.email "tester@example.com"
  echo "initial" > "${dir}/local/file.txt"
  git -C "${dir}/local" add file.txt
  git -C "${dir}/local" commit -m "chore: initial commit" >/dev/null 2>&1
  git -C "${dir}/local" push origin main >/dev/null 2>&1
}

echo "=== Running action-semantic-release Retry Test Suite ==="

# Advances the remote, resolves the config and mocks a first attempt that is behind remote.
prepare_release_behind_remote() {
  local tdir="$1"

  mkdir -p "${tdir}/other"
  git clone "${tdir}/remote" "${tdir}/other" >/dev/null 2>&1
  git -C "${tdir}/other" config user.name "other"
  git -C "${tdir}/other" config user.email "other@example.com"
  echo "remote update" > "${tdir}/other/remote.txt"
  git -C "${tdir}/other" add remote.txt
  git -C "${tdir}/other" commit -m "feat: concurrent commit" >/dev/null 2>&1
  git -C "${tdir}/other" push origin main >/dev/null 2>&1

  local mock_sr="${tdir}/mock-sr.sh"
  local state_file="${tdir}/attempt.txt"
  cat << EOF > "${mock_sr}"
#!/usr/bin/env bash
ATTEMPT=\$(cat "${state_file}" 2>/dev/null || echo 1)
if [ "\${ATTEMPT}" -eq 1 ]; then
  echo 2 > "${state_file}"
  if [ -x "${tdir}/attempt1-hook.sh" ]; then "${tdir}/attempt1-hook.sh"; fi
  echo "dummy" > local-unpushed.txt
  git add local-unpushed.txt
  git commit -m "chore(release): 1.1.0" >/dev/null 2>&1
  git tag "v1.1.0" >/dev/null 2>&1
  echo "[semantic-release] › ℹ  The local branch main is behind the remote one, therefore a new version won't be published."
  exit 0
else
  cp .releaserc.cjs "${tdir}/attempt2-config.cjs" 2>/dev/null || true
  echo "new_release_published=true" >> "\${GITHUB_ENV}"
  exit 0
fi
EOF
  chmod +x "${mock_sr}"

  export GITHUB_OUTPUT="${tdir}/github_output.txt"
  export GITHUB_ENV="${tdir}/github_env.txt"
  export GITHUB_REF_NAME="main"
  export DEFAULT_BRANCH="main"
  export INPUT_ENABLE_MONOREPO="false"
  export INPUT_EXTRA_PLUGINS=""
  export INPUT_DRY_RUN="false"
  export INPUT_RETRY_ON_REMOTE_AHEAD="true"
  export SEMANTIC_RELEASE="${mock_sr}"
  touch "${GITHUB_OUTPUT}" "${GITHUB_ENV}"

  (cd "${tdir}/local" && GITHUB_ACTION_PATH="${SCRIPT_DIR}/.." "${RESOLVE_SCRIPT}") >/dev/null
}

test_retry_when_behind_remote() {
  local tdir="${TEMP_ROOT}/test1"
  setup_repo "${tdir}"

  # Place untracked .npmrc to verify it survives git clean on retry
  echo "//npm.pkg.github.com/:_authToken=dummy-token" > "${tdir}/local/.npmrc"
  echo "leftover" > "${tdir}/local/stray.txt"

  prepare_release_behind_remote "${tdir}"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >/dev/null 2>&1
  local res=$?
  set -e

  if [ "${res}" -ne 0 ]; then
    echo "FAIL: Expected test 1 to exit 0, got ${res}" >&2
    exit 1
  fi

  if ! grep -q "^new_release_published=true$" "${GITHUB_OUTPUT}"; then
    echo "FAIL: Expected new_release_published=true in GITHUB_OUTPUT" >&2
    exit 1
  fi

  if [ ! -f "${tdir}/local/.npmrc" ]; then
    echo "FAIL: Expected .npmrc to be preserved across retry" >&2
    exit 1
  fi

  if ! cmp -s "${SCRIPT_DIR}/../.releaserc.cjs" "${tdir}/attempt2-config.cjs"; then
    echo "FAIL: Expected the retry to run with the default .releaserc.cjs" >&2
    exit 1
  fi

  if [ -e "${tdir}/local/stray.txt" ]; then
    echo "FAIL: Expected untracked stray.txt to be removed by the retry clean" >&2
    exit 1
  fi

  if [ -f "${tdir}/local/local-unpushed.txt" ]; then
    echo "FAIL: Expected unpushed file local-unpushed.txt to be removed by reset" >&2
    exit 1
  fi

  if git -C "${tdir}/local" rev-parse "v1.1.0" >/dev/null 2>&1; then
    echo "FAIL: Expected unpushed tag v1.1.0 to be deleted" >&2
    exit 1
  fi

  local merge_count
  merge_count=$(git -C "${tdir}/local" log --merges --oneline | wc -l | xargs)
  if [ "${merge_count}" -ne 0 ]; then
    echo "FAIL: Expected 0 merge commits, found ${merge_count}" >&2
    exit 1
  fi

  echo "PASS: test_retry_when_behind_remote"
}

# Keeping the default copy through the retry clean would block this fast-forward.
test_retry_picks_up_config_added_meanwhile() {
  local tdir="${TEMP_ROOT}/test4"
  setup_repo "${tdir}"

  prepare_release_behind_remote "${tdir}"

  cat << EOF > "${tdir}/attempt1-hook.sh"
#!/usr/bin/env bash
echo "module.exports = { consumer: true };" > "${tdir}/other/.releaserc.cjs"
git -C "${tdir}/other" add .releaserc.cjs
git -C "${tdir}/other" commit -m "chore: add own release config" >/dev/null 2>&1
git -C "${tdir}/other" push origin main >/dev/null 2>&1
EOF
  chmod +x "${tdir}/attempt1-hook.sh"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >/dev/null 2>&1
  local res=$?
  set -e

  if [ "${res}" -ne 0 ]; then
    echo "FAIL: Expected test 4 to exit 0, got ${res}" >&2
    exit 1
  fi

  if ! grep -q "consumer: true" "${tdir}/attempt2-config.cjs" 2>/dev/null; then
    echo "FAIL: Expected the retry to use the release config added on the remote meanwhile" >&2
    exit 1
  fi

  echo "PASS: test_retry_picks_up_config_added_meanwhile"
}

# Fails unless release.sh exited non-zero with the uncommitted-config error before attempt 2.
assert_retry_aborted() {
  local tdir="$1"
  local res="$2"
  local label="$3"

  if [ "${res}" -eq 0 ] || [ -e "${tdir}/attempt2-config.cjs" ]; then
    echo "FAIL: Expected the retry to abort on ${label}, got exit ${res}" >&2
    exit 1
  fi

  if ! grep -q "has uncommitted changes that a retry would discard" "${tdir}/release.log"; then
    echo "FAIL: Expected the uncommitted-config error for ${label}" >&2
    exit 1
  fi
}

commit_and_push() {
  local tdir="$1"
  local name="$2"
  local content="$3"

  mkdir -p "$(dirname "${tdir}/local/${name}")"
  echo "${content}" > "${tdir}/local/${name}"
  git -C "${tdir}/local" add "${name}"
  git -C "${tdir}/local" commit -m "chore: add ${name}" >/dev/null 2>&1
  git -C "${tdir}/local" push origin main >/dev/null 2>&1
}

# Leaves ${name} uncommitted; a tracked config, if given, is what resolve-config.sh picks.
test_retry_aborts_on_uncommitted_config() {
  local name="$1"
  local tracked="${2:-}"
  local source="${3:-}"
  local tdir
  tdir=$(mktemp -d "${TEMP_ROOT}/test-uncommitted.XXXXXX")
  setup_repo "${tdir}"

  if [ -n "${tracked}" ]; then
    commit_and_push "${tdir}" "${tracked}" "module.exports = { committed: true };"
  fi
  if [ -n "${source}" ]; then
    cp "${source}" "${tdir}/local/${name}"
  else
    echo "{}" > "${tdir}/local/${name}"
  fi
  # git clean ignores this setting, git status does not.
  git -C "${tdir}/local" config status.showUntrackedFiles no
  prepare_release_behind_remote "${tdir}"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >"${tdir}/release.log" 2>&1
  local res=$?
  set -e

  assert_retry_aborted "${tdir}" "${res}" "an uncommitted ${name}"

  if [ ! -f "${tdir}/local/${name}" ]; then
    echo "FAIL: Expected ${name} left in place" >&2
    exit 1
  fi

  echo "PASS: test_retry_aborts_on_uncommitted_config ${name} ${tracked}"
}

# Commits ${name}, then overwrites the working copy with ${local_source} before the release.
test_retry_aborts_on_modified_tracked_config() {
  local name="$1"
  local local_source="$2"
  local tdir="${TEMP_ROOT}/test-modified-tracked-${name}"
  setup_repo "${tdir}"

  commit_and_push "${tdir}" "${name}" "module.exports = { committed: true };"
  cp "${local_source}" "${tdir}/local/${name}"
  prepare_release_behind_remote "${tdir}"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >"${tdir}/release.log" 2>&1
  local res=$?
  set -e

  assert_retry_aborted "${tdir}" "${res}" "a locally edited tracked ${name}"

  echo "PASS: test_retry_aborts_on_modified_tracked_config ${name}"
}

# The exclude pathspec is relative to the working directory, so a copy in sub dir/ is exempt.
test_retry_from_subdirectory() {
  local tdir="${TEMP_ROOT}/test-subdirectory"
  setup_repo "${tdir}"

  commit_and_push "${tdir}" "sub dir/.keep" ""
  prepare_release_behind_remote "${tdir}"
  (cd "${tdir}/local/sub dir" && GITHUB_ACTION_PATH="${SCRIPT_DIR}/.." "${RESOLVE_SCRIPT}") >/dev/null

  set +e
  (cd "${tdir}/local/sub dir" && "${RELEASE_SCRIPT}") >"${tdir}/release.log" 2>&1
  local res=$?
  set -e

  if [ "${res}" -ne 0 ] || ! cmp -s "${SCRIPT_DIR}/../.releaserc.cjs" "${tdir}/attempt2-config.cjs"; then
    echo "FAIL: Expected a retry from 'sub dir/' with the default .releaserc.cjs, got exit ${res}" >&2
    exit 1
  fi

  echo "PASS: test_retry_from_subdirectory"
}

# Only root-level config files count; a file inside a .releaserc* directory must not abort.
test_retry_ignores_nested_config_paths() {
  local tdir="${TEMP_ROOT}/test-nested"
  setup_repo "${tdir}"

  mkdir -p "${tdir}/local/.releaserc.d"
  echo "notes" > "${tdir}/local/.releaserc.d/notes.txt"
  prepare_release_behind_remote "${tdir}"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >"${tdir}/release.log" 2>&1
  local res=$?
  set -e

  if [ "${res}" -ne 0 ] || [ ! -e "${tdir}/attempt2-config.cjs" ]; then
    echo "FAIL: Expected the retry to ignore .releaserc.d/notes.txt, got exit ${res}" >&2
    exit 1
  fi

  echo "PASS: test_retry_ignores_nested_config_paths"
}

# Without a retry nothing is reset, so an uncommitted config must not fail the run.
test_no_guard_when_retry_disabled() {
  local tdir="${TEMP_ROOT}/test-no-guard"
  setup_repo "${tdir}"

  echo "{}" > "${tdir}/local/.releaserc.json"
  prepare_release_behind_remote "${tdir}"
  export INPUT_RETRY_ON_REMOTE_AHEAD="false"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >"${tdir}/release.log" 2>&1
  local res=$?
  set -e

  if [ "${res}" -ne 0 ] || grep -q "has uncommitted changes" "${tdir}/release.log"; then
    echo "FAIL: Expected no uncommitted-config check without a retry, got exit ${res}" >&2
    exit 1
  fi

  echo "PASS: test_no_guard_when_retry_disabled"
}

test_retry_keeps_ignored_config() {
  local tdir="${TEMP_ROOT}/test-ignored"
  setup_repo "${tdir}"

  commit_and_push "${tdir}" .gitignore ".releaserc.json"
  echo '{"ignored":true}' > "${tdir}/local/.releaserc.json"
  prepare_release_behind_remote "${tdir}"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >/dev/null 2>&1
  local res=$?
  set -e

  if [ "${res}" -ne 0 ] || ! grep -q "ignored" "${tdir}/local/.releaserc.json" \
    || ! grep -q "^new_release_published=true$" "${GITHUB_OUTPUT}"; then
    echo "FAIL: Expected the retry to keep the gitignored .releaserc.json, got exit ${res}" >&2
    exit 1
  fi

  echo "PASS: test_retry_keeps_ignored_config"
}

test_abort_on_divergence_conflict() {
  local tdir="${TEMP_ROOT}/test2"
  setup_repo "${tdir}"

  mkdir -p "${tdir}/other"
  git clone "${tdir}/remote" "${tdir}/other" >/dev/null 2>&1
  git -C "${tdir}/other" config user.name "other"
  git -C "${tdir}/other" config user.email "other@example.com"
  echo "from remote" > "${tdir}/other/file.txt"
  git -C "${tdir}/other" commit -am "remote update" >/dev/null 2>&1
  git -C "${tdir}/other" push origin main >/dev/null 2>&1

  echo "from local" > "${tdir}/local/file.txt"
  git -C "${tdir}/local" commit -am "local conflicting update" >/dev/null 2>&1

  local mock_sr="${tdir}/mock-sr.sh"
  cat << 'EOF' > "${mock_sr}"
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "${mock_sr}"

  export GITHUB_OUTPUT="${tdir}/github_output.txt"
  export GITHUB_ENV="${tdir}/github_env.txt"
  export GITHUB_REF_NAME="main"
  export DEFAULT_BRANCH="main"
  export INPUT_ENABLE_MONOREPO="false"
  export INPUT_EXTRA_PLUGINS=""
  export INPUT_DRY_RUN="false"
  export INPUT_RETRY_ON_REMOTE_AHEAD="true"
  export SEMANTIC_RELEASE="${mock_sr}"
  touch "${GITHUB_OUTPUT}" "${GITHUB_ENV}"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >/dev/null 2>&1
  local res=$?
  set -e

  if [ "${res}" -eq 0 ]; then
    echo "FAIL: Expected test 2 to fail on divergence, got exit 0" >&2
    exit 1
  fi

  echo "PASS: test_abort_on_divergence_conflict"
}

test_no_retry_when_disabled() {
  local tdir="${TEMP_ROOT}/test3"
  setup_repo "${tdir}"

  local mock_sr="${tdir}/mock-sr.sh"
  local state_file="${tdir}/attempt.txt"
  cat << EOF > "${mock_sr}"
#!/usr/bin/env bash
ATTEMPT=\$(cat "${state_file}" 2>/dev/null || echo 1)
echo \$((ATTEMPT + 1)) > "${state_file}"
echo "[semantic-release] › ℹ  The local branch main is behind the remote one, therefore a new version won't be published."
exit 0
EOF
  chmod +x "${mock_sr}"

  export GITHUB_OUTPUT="${tdir}/github_output.txt"
  export GITHUB_ENV="${tdir}/github_env.txt"
  export GITHUB_REF_NAME="main"
  export DEFAULT_BRANCH="main"
  export INPUT_ENABLE_MONOREPO="false"
  export INPUT_EXTRA_PLUGINS=""
  export INPUT_DRY_RUN="false"
  export INPUT_RETRY_ON_REMOTE_AHEAD="false"
  export SEMANTIC_RELEASE="${mock_sr}"
  touch "${GITHUB_OUTPUT}" "${GITHUB_ENV}"

  set +e
  (cd "${tdir}/local" && "${RELEASE_SCRIPT}") >/dev/null 2>&1
  local res=$?
  set -e

  if [ "${res}" -ne 0 ]; then
    echo "FAIL: Expected test 3 to exit 0, got ${res}" >&2
    exit 1
  fi

  local total_attempts
  total_attempts=$(cat "${state_file}")
  if [ "${total_attempts}" -ne 2 ]; then
    echo "FAIL: Expected exactly 1 attempt when retry is disabled, but attempt count was ${total_attempts}" >&2
    exit 1
  fi

  if ! grep -q "^new_release_published=false$" "${GITHUB_OUTPUT}"; then
    echo "FAIL: Expected new_release_published=false in GITHUB_OUTPUT" >&2
    exit 1
  fi

  echo "PASS: test_no_retry_when_disabled"
}

(test_retry_when_behind_remote)
(test_abort_on_divergence_conflict)
(test_no_retry_when_disabled)
(test_retry_picks_up_config_added_meanwhile)
(test_retry_aborts_on_uncommitted_config .releaserc.json)
(test_retry_aborts_on_uncommitted_config .releaserc-config.json)
(test_retry_aborts_on_uncommitted_config .releaserc.cjs)
(test_retry_aborts_on_uncommitted_config .releaserc.json .releaserc.cjs)
(test_retry_aborts_on_uncommitted_config release.config.js)
(test_retry_aborts_on_uncommitted_config release.config.mjs)
(test_retry_aborts_on_uncommitted_config .ReleaseRC.json)
(test_retry_aborts_on_uncommitted_config .releaserc.js "" "${SCRIPT_DIR}/../.releaserc.cjs")
LOCAL_EDIT="${TEMP_ROOT}/local-edit.json"
echo '{"local-edit":true}' > "${LOCAL_EDIT}"
(test_retry_aborts_on_modified_tracked_config .releaserc.json "${LOCAL_EDIT}")
(test_retry_aborts_on_modified_tracked_config .releaserc.cjs "${SCRIPT_DIR}/../.releaserc.cjs")
(test_retry_keeps_ignored_config)
(test_retry_ignores_nested_config_paths)
(test_no_guard_when_retry_disabled)
(test_retry_from_subdirectory)

echo "All action-semantic-release tests passed successfully!"
