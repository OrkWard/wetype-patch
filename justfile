[unix]
set shell := ["bash", "-euo", "pipefail", "-c"]

[windows]
set shell := ["nu", "-c"]

# Only evaluate variables a recipe uses (the MSVC lookup runs for `build` only).
set lazy

[macos]
input := env_var_or_default("WETYPE_INPUT", "original/WeType.app")
[macos]
output := env_var_or_default("WETYPE_OUTPUT", "build/WeType.app")
[macos]
profile := env_var_or_default("WETYPE_PROFILE", "profiles/wetype-2.2.3-657.json")
[macos]
installed := "/Library/Input Methods/WeType.app"
[macos]
cli := installed + "/Contents/MacOS/wetype-cli"

[windows]
cli := 'C:\Program Files\Tencent\WeType\wetype-mode\wetype-cli.exe'
# "overlay use '<portable MSVC>\activate.nu' as msvc"
[windows]
msvc := `portablemsvc get-activate --shell nu`

# Shell prefix that runs the CLI (bash quoting / nushell external call).
[macos]
run := '"' + cli + '"'
[windows]
run := "^'" + cli + "'"

default:
    @just --list

# Build and verify in a temporary directory, then replace the output app.
[macos]
build input=input output=output profile=profile:
    mkdir -p "$(dirname "{{ output }}")"
    python3 -B patch.py build --input "{{ input }}" --output "{{ output }}" --profile "{{ profile }}" --english-entry

[macos]
verify app=output:
    python3 -B patch.py verify "{{ app }}"

[macos]
inspect app=input:
    python3 -B patch.py inspect "{{ app }}"

# Atomically replace the system app. This is the only recipe requiring sudo.
[macos]
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

[macos]
restart:
    pkill -x WeType 2>/dev/null || true

# Build build/wetype-cli.exe with portable MSVC (x64).
[windows]
build:
    {{ msvc }}; mkdir build; cd build; ^cl /nologo /std:c++17 /EHsc /O2 /W4 /WX /utf-8 /MT ../src/windows/wetype-cli.cpp /Fe:wetype-cli.exe /link /SUBSYSTEM:CONSOLE

# Restart the daemon through the logon task.
[windows]
restart:
    {{ run }} stop | complete | ignore; sleep 500ms; {{ run }} start

[windows]
toggle:
    {{ run }} toggle

# System Ctrl+Space IME hotkey: show, or `just hotkey fix|restore`.
[windows]
hotkey *action:
    {{ run }} hotkey {{ action }}

status:
    {{ run }} status

auto-status:
    {{ run }} auto-status

apps:
    {{ run }} apps

# BUNDLE is a bundle ID on macOS, an exe name on Windows.
app-set bundle mode:
    {{ run }} app-set "{{ bundle }}" "{{ mode }}"

app-forget bundle:
    {{ run }} app-forget "{{ bundle }}"

auto-on:
    {{ run }} auto-on

auto-off:
    {{ run }} auto-off

chinese:
    {{ run }} chinese

english:
    {{ run }} english
