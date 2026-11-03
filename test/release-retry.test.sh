#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_SCRIPT="${SCRIPT_DIR}/../scripts/release.sh"
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

test_retry_when_behind_remote() {
  local tdir="${TEMP_ROOT}/test1"
  setup_repo "${tdir}"

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
  echo "dummy" > local-unpushed.txt
  git add local-unpushed.txt
  git commit -m "chore(release): 1.1.0" >/dev/null 2>&1
  git tag "v1.1.0" >/dev/null 2>&1
  echo "[semantic-release] › ℹ  The local branch main is behind the remote one, therefore a new version won't be published."
  exit 0
else
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

  local merge_count
  merge_count=$(git -C "${tdir}/local" log --merges --oneline | wc -l | xargs)
  if [ "${merge_count}" -ne 0 ]; then
    echo "FAIL: Expected 0 merge commits, found ${merge_count}" >&2
    exit 1
  fi

  echo "PASS: test_retry_when_behind_remote"
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

echo "All action-semantic-release tests passed successfully!"
