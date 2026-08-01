# log-watcher build entry points (`just --list` shows this menu)

default: release

# release build -> bin/Main
release:
    @haxe build.hxml --times

# same with debug symbols
debug:
    @haxe build.hxml --times -debug

# static libstdc++/libgcc for mixed-distro fleets; glibc stays dynamic (doc/install.md)
portable:
    @haxe build.hxml --times -D portable
    @ldd bin/Main

run:
    @bin/Main

# test suite on the interpreter (fast dev loop)
test:
    @haxe test.hxml

# same suite compiled native (required before calling work done)
test-native:
    @haxe test-native.hxml --times
    @bin/test/TestMain

# end-to-end demo on the committed fixture (~2.5 min)
demo:
    @test/demo.sh

clean:
    @rm -rf bin

# versioned tar.gz in .releases/: binary (as log-watcher) + deploy/ + install guide
package: release
    #!/usr/bin/env bash
    set -euo pipefail
    name="build-$(git log --pretty='format:%h' -n1)-$(date '+%Y%m%d%H%M')"
    dir=".releases/${name}"
    mkdir -p "${dir}"
    cp bin/Main "${dir}/log-watcher"
    cp -R deploy "${dir}/"
    cp doc/install.md justfile "${dir}/"
    tar -czf ".releases/log-watcher-${name}.tar.gz" -C .releases "${name}"
    rm -rf "${dir}"
    echo ".releases/log-watcher-${name}.tar.gz"

# binary -> <prefix>/bin/log-watcher; build first (`just release`), only the copy elevates
install prefix="/usr/local":
    #!/usr/bin/env bash
    set -euo pipefail
    [ -x bin/Main ] || { echo "no bin/Main — run 'just release' first" >&2; exit 1; }
    dest="{{prefix}}/bin"
    check="${dest}"; [ -d "${check}" ] || check="{{prefix}}"
    SUDO=""
    if [ "$(id -u)" -ne 0 ] && [ ! -w "${check}" ]; then SUDO="sudo"; fi
    ${SUDO} install -D -m 755 bin/Main "${dest}/log-watcher"

# cross-build in a target-distro container -> dist/<target>/log-watcher
cross-build target="rocky9":
    docker build -f deploy/Containerfile.{{target}} --target out -o dist/{{target}} .
    @ls -l dist/{{target}}/

# create the log-watcher system user (no-op when it exists)
setup-user:
    #!/usr/bin/env bash
    set -euo pipefail
    id -u log-watcher >/dev/null 2>&1 && { echo "user log-watcher exists"; exit 0; }
    sudo useradd --system --no-create-home --shell /usr/sbin/nologin log-watcher

# /opt/log-watcher/{config.json,.env}: gitignored deploy/*.local.* variants win and
# always sync; samples only fill gaps, never overwrite
setup-config: setup-user
    #!/usr/bin/env bash
    set -euo pipefail
    sudo mkdir -p /opt/log-watcher
    if [ -f deploy/config.local.json ]; then
        sudo cp deploy/config.local.json /opt/log-watcher/config.json
        echo "config.json <- deploy/config.local.json"
    elif [ -f /opt/log-watcher/config.json ]; then echo "config.json exists — kept"; else
        sudo cp deploy/config.sample.json /opt/log-watcher/config.json; fi
    if [ -f deploy/.env.local ]; then
        sudo cp deploy/.env.local /opt/log-watcher/.env
        echo ".env <- deploy/.env.local"
    elif [ -f /opt/log-watcher/.env ]; then echo ".env exists — kept"; else
        sudo cp deploy/.env.example /opt/log-watcher/.env; fi
    sudo chown root:log-watcher /opt/log-watcher/.env
    sudo chmod 640 /opt/log-watcher/.env
    echo "edit /opt/log-watcher/config.json (services, logs) and .env (LOG_WATCHER_API_KEY)"

# systemd units + daemon-reload; deploy/<unit>.local.service variants win (does not start anything)
setup-units:
    #!/usr/bin/env bash
    set -euo pipefail
    for u in log-watcher log-watcher-mcp; do
        src="deploy/${u}.service"
        [ -f "deploy/${u}.local.service" ] && src="deploy/${u}.local.service"
        sudo cp "${src}" "/etc/systemd/system/${u}.service"
        echo "${u}.service <- ${src}"
    done
    sudo systemctl daemon-reload

# full server setup: binary + user + config + units — then edit config, `just enable`
setup: install setup-config setup-units
    @echo "next: edit /opt/log-watcher/{config.json,.env}, then: just enable"

# enable + start both services (refuses while the API key is still the sample)
enable:
    #!/usr/bin/env bash
    set -euo pipefail
    if sudo grep -q "^LOG_WATCHER_API_KEY=change-me" /opt/log-watcher/.env; then
        echo "set a real LOG_WATCHER_API_KEY in /opt/log-watcher/.env first: openssl rand -hex 32" >&2
        exit 1
    fi
    sudo systemctl enable --now log-watcher log-watcher-mcp
    systemctl --no-pager -n 0 status log-watcher log-watcher-mcp || true

# remove services + binary; config/user kept unless: just uninstall /usr/local purge
uninstall prefix="/usr/local" purge="keep":
    #!/usr/bin/env bash
    set -euo pipefail
    # services (tolerate a partial install)
    sudo systemctl disable --now log-watcher log-watcher-mcp 2>/dev/null || true
    sudo rm -f /etc/systemd/system/log-watcher.service /etc/systemd/system/log-watcher-mcp.service
    sudo systemctl daemon-reload
    # binary
    sudo rm -f "{{prefix}}/bin/log-watcher"
    if [ "{{purge}}" = "purge" ]; then
        sudo rm -rf /opt/log-watcher
        sudo userdel log-watcher 2>/dev/null || true
        echo "removed: services, binary, /opt/log-watcher (config + key), user log-watcher"
    else
        echo "removed: services, binary. kept: /opt/log-watcher (config + key), user log-watcher"
        echo "full wipe: just uninstall {{prefix}} purge"
    fi

# health check: unit status + authenticated MCP ping (port read from config)
verify:
    #!/usr/bin/env bash
    set -euo pipefail
    systemctl --no-pager -n 3 status log-watcher log-watcher-mcp || true
    port=$(grep -oP '"port"\s*:\s*\K[0-9]+' /opt/log-watcher/config.json)
    key=$(sudo grep -oP '(?<=^LOG_WATCHER_API_KEY=).*' /opt/log-watcher/.env)
    curl -s -X POST "http://127.0.0.1:${port}/mcp" \
        -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","id":1,"method":"ping"}'
    echo
