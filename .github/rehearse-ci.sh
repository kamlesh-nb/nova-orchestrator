#!/usr/bin/env bash
# Rehearse the two ci.yml test steps locally, with the SAME shell logic, so a change to the
# workflow can be checked without pushing. Takes the paths CI derives from $GITHUB_WORKSPACE
# from the environment instead: LANG_DIR and ORCH.
set -u
LANG_DIR="${LANG_DIR:-$HOME/nova}"
ORCH="${ORCH:-$HOME/packages/nova-orchestrator}"
export PATH="$HOME/.nova/bin:$PATH"
cd "$LANG_DIR" || { echo "no lang dir at $LANG_DIR"; exit 1; }

echo "=== step 1: core tests (unprivileged, 183 skipped) ==="
pass=0; fail=0; skipped=0
for t in "$ORCH"/tests/*.nova; do
  case "$(basename "$t")" in
    183_isolation_sandbox.nova) echo "SKIP  $(basename "$t")  (root step below)"; skipped=$((skipped+1)); continue ;;
  esac
  if nova test "$t" >/tmp/orch.log 2>&1 && grep -q "0 failed" /tmp/orch.log; then
    pass=$((pass+1))
  else
    echo "::error::FAIL $(basename "$t")"; tail -8 /tmp/orch.log; fail=$((fail+1))
  fi
done
echo "orchestrator core: $pass passed, $fail failed, $skipped skipped"
step1=$fail

echo
echo "=== step 2: isolation test (root) ==="
# GitHub runners have PASSWORDLESS sudo; a dev box usually does not, and a plain `sudo` would then
# block on a password prompt with no tty and hang the rehearsal. Probe with -n first and say so.
if ! sudo -n true 2>/dev/null; then
  echo "SKIP  sudo needs a password here, so step 2 cannot be rehearsed locally."
  echo "      On a GitHub runner sudo is passwordless and this step runs as written."
  echo "      To check it by hand:  sudo env \"PATH=\$PATH\" \"HOME=\$HOME\" nova test \\"
  echo "                              $ORCH/tests/183_isolation_sandbox.nova"
  echo "rehearsal: step1 fail=$step1  step2 SKIPPED"
  exit "$step1"
fi
rc=0
sudo env "PATH=$PATH" "HOME=$HOME" \
  nova test "$ORCH/tests/183_isolation_sandbox.nova" >/tmp/orch183.log 2>&1 \
  && grep -q "0 failed" /tmp/orch183.log || rc=1
if [ "$rc" -eq 0 ]; then
  echo "PASS  183_isolation_sandbox.nova (root)"
else
  echo "::error::FAIL 183_isolation_sandbox.nova (root)"; tail -12 /tmp/orch183.log
fi
sudo find /tmp -maxdepth 1 -user root -name 'nova*' -exec rm -rf {} + 2>/dev/null || true

echo
echo "rehearsal: step1 fail=$step1  step2 rc=$rc"
[ "$step1" -eq 0 ] && [ "$rc" -eq 0 ]
