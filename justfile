set shell := ["bash", "-euo", "pipefail", "-c"]

input := env_var_or_default("WETYPE_INPUT", "original/WeType.app")
output := env_var_or_default("WETYPE_OUTPUT", "build/WeType.app")
profile := env_var_or_default("WETYPE_PROFILE", "profiles/wetype-2.2.3-657.json")
installed := "/Library/Input Methods/WeType.app"
cli := installed + "/Contents/MacOS/wetype-cli"

default:
    @just --list

# Build and verify in a temporary directory, then replace the output app.
build input=input output=output profile=profile:
    mkdir -p "$(dirname "{{ output }}")"
    python3 -B patch.py build --input "{{ input }}" --output "{{ output }}" --profile "{{ profile }}" --english-entry

verify app=output:
    python3 -B patch.py verify "{{ app }}"

inspect app=input:
    python3 -B patch.py inspect "{{ app }}"

# Atomically replace the system app. This is the only recipe requiring sudo.
install app=output:
    #!/usr/bin/env bash
    set -euo pipefail
    python3 -B patch.py verify "{{ app }}"
    target="{{ installed }}"
    stage="/Library/Input Methods/.WeType.app.stage.$$"
    backup="/Library/Input Methods/.WeType.app.backup.$$"
    test -d "$target"
    test ! -e "$stage"
    test ! -e "$backup"
    sudo ditto "{{ app }}" "$stage"
    python3 -B patch.py verify "$stage"
    sudo mv "$target" "$backup"
    if sudo mv "$stage" "$target"; then
        sudo rm -rf "$backup"
    else
        sudo mv "$backup" "$target"
        exit 1
    fi
    pkill -x WeType 2>/dev/null || true
    echo "Installed. Select WeType or focus a text field to start the new process."

restart:
    pkill -x WeType 2>/dev/null || true

status:
    "{{ cli }}" status

auto-status:
    "{{ cli }}" auto-status

apps:
    "{{ cli }}" apps

app-set bundle mode:
    "{{ cli }}" app-set "{{ bundle }}" "{{ mode }}"

app-forget bundle:
    "{{ cli }}" app-forget "{{ bundle }}"

auto-on:
    "{{ cli }}" auto-on

auto-off:
    "{{ cli }}" auto-off

chinese:
    "{{ cli }}" chinese

english:
    "{{ cli }}" english
