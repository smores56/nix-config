#!/usr/bin/env bash
# Runs the generated __load_ssh_keys fish function against a scratch
# ssh-agent: every present key gets loaded, an already-loaded key is not
# re-added, and a missing key is skipped. Usage: ssh_agent_keys.sh <fn.fish>
set -euo pipefail

fn=$1
export HOME=$PWD/home
mkdir -p "$HOME/.ssh"
for key in id_personal id_work; do
  ssh-keygen -q -t ed25519 -N "" -C "$key" -f "$HOME/.ssh/$key"
done
eval "$(ssh-agent -s -a "$PWD/agent.sock")" >/dev/null
trap 'ssh-agent -k >/dev/null' EXIT
failures=0

loaded() { ssh-add -l 2>/dev/null | grep -c . || true; }
check() {
  if [[ $2 != "$3" ]]; then
    echo "FAIL $1: want $3, got $2"
    failures=$((failures + 1))
  fi
}

ssh-add -q "$HOME/.ssh/id_personal"
fish --no-config -c "source $fn; __load_ssh_keys"
check "both keys loaded when one already was" "$(loaded)" 2

fish --no-config -c "source $fn; __load_ssh_keys"
check "rerun adds nothing" "$(loaded)" 2

ssh-add -qD
rm "$HOME/.ssh/id_work" "$HOME/.ssh/id_work.pub"
fish --no-config -c "source $fn; __load_ssh_keys"
check "missing key skipped" "$(loaded)" 1

if ((failures)); then
  echo "$failures agent expectation(s) failed"
  exit 1
fi
echo "ssh agent keys: ok"
