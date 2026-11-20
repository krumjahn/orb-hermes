#!/usr/bin/env bash
#
# yaml-python.sh - find a Python that can read YAML.
#
# The Beelink scripts read and repair ~/.hermes/config.yaml, and the tests
# that check them need a YAML parser to verify the result. The system Python
# usually has no PyYAML, so this looks for one in the places it might be:
#
#   * $ORB_YAML_PYTHON          - set it yourself and it wins
#   * beelink/.venv/bin/python  - the venv the installer makes
#   * python3 / python          - if they already have PyYAML
#   * a throwaway venv          - created once, with PyYAML installed
#
# Usage:
#   . "$(dirname "$0")/yaml-python.sh"
#   PY="$(yaml_python)" || echo "no YAML python available"
#
# yaml_python prints the interpreter on stdout, or nothing and returns 1.

yaml_python() {
    # 1. the user knows best
    if [ -n "${ORB_YAML_PYTHON:-}" ] && "$ORB_YAML_PYTHON" -c "import yaml" 2>/dev/null; then
        printf '%s' "$ORB_YAML_PYTHON"
        return 0
    fi

    # 2. the venv the installer creates
    local here="${1:-.}"
    for candidate in "$here/beelink/.venv/bin/python" "$here/../beelink/.venv/bin/python"; do
        if [ -x "$candidate" ] && "$candidate" -c "import yaml" 2>/dev/null; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    # 3. a system Python that already has PyYAML
    for candidate in python3 python python3.13 python3.12 python3.11; do
        if command -v "$candidate" >/dev/null 2>&1 && \
           "$candidate" -c "import yaml" 2>/dev/null; then
            command -v "$candidate"
            return 0
        fi
    done

    # 4. make one. It needs a network, so it is the last resort.
    local cache="${ORB_YAML_VENV:-${TMPDIR:-/tmp}/orb-yaml-venv}"
    if [ ! -x "$cache/bin/python" ]; then
        command -v python3 >/dev/null 2>&1 || return 1
        python3 -m venv "$cache" >/dev/null 2>&1 || return 1
    fi
    if "$cache/bin/python" -c "import yaml" 2>/dev/null; then
        printf '%s' "$cache/bin/python"
        return 0
    fi
    "$cache/bin/pip" install --quiet --disable-pip-version-check pyyaml >/dev/null 2>&1 || return 1
    "$cache/bin/python" -c "import yaml" 2>/dev/null || return 1
    printf '%s' "$cache/bin/python"
    return 0
}
