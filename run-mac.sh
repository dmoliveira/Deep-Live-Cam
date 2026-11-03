#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="$PROJECT_ROOT/venv"
DRY_RUN=0

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=1
    shift
fi

note() {
    printf '[launcher] %s\n' "$*"
}

die() {
    printf '[launcher] ERROR: %s\n' "$*" >&2
    exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    die 'This launcher only supports macOS.'
fi

MACHINE="$(uname -m)"
ARM64_AVAILABLE="$(sysctl -n hw.optional.arm64 2>/dev/null || true)"
IS_APPLE_SILICON=0
if [[ "$MACHINE" == "arm64" || "$ARM64_AVAILABLE" == "1" ]]; then
    IS_APPLE_SILICON=1
fi

if [[ "$IS_APPLE_SILICON" == "1" && -x /opt/homebrew/bin/brew ]]; then
    BREW=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
    BREW=/usr/local/bin/brew
else
    BREW="$(command -v brew || true)"
fi
[[ -n "$BREW" ]] || die 'Homebrew is required. Install it from https://brew.sh, then rerun this script.'

export HOMEBREW_NO_AUTO_UPDATE=1
BREW_PREFIX="$("$BREW" --prefix)"
export PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"

find_python() {
    local candidate
    for candidate in \
        "$BREW_PREFIX/opt/python@3.14/bin/python3.14" \
        "$BREW_PREFIX/bin/python3.14"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    command -v python3.14 || true
}

PYTHON_BIN="$(find_python || true)"
if [[ -z "$PYTHON_BIN" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        note 'Would install Python 3.14 with Homebrew.'
    else
        note 'Installing Python 3.14 with Homebrew.'
        "$BREW" install python@3.14
        PYTHON_BIN="$(find_python || true)"
        [[ -n "$PYTHON_BIN" ]] || die 'Homebrew installed Python 3.14, but python3.14 was not found.'
    fi
fi

if [[ -n "$PYTHON_BIN" ]]; then
    PYTHON_VERSION="$("$PYTHON_BIN" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    [[ "$PYTHON_VERSION" == "3.14" ]] || die "Found Python $PYTHON_VERSION at $PYTHON_BIN; this project recommends Python 3.14."

    PYTHON_ARCH="$("$PYTHON_BIN" -c 'import platform; print(platform.machine())')"
    if [[ "$IS_APPLE_SILICON" == "1" && "$PYTHON_ARCH" != "arm64" ]]; then
        die "Python at $PYTHON_BIN is $PYTHON_ARCH, not native arm64. Install native Apple Silicon Homebrew under /opt/homebrew and rerun."
    fi
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
        note 'Would install ffmpeg with Homebrew.'
    else
        note 'Installing ffmpeg with Homebrew.'
        "$BREW" install ffmpeg
        command -v ffmpeg >/dev/null 2>&1 || die 'Homebrew installed ffmpeg, but it is not available on PATH.'
    fi
fi

if [[ -n "$PYTHON_BIN" ]] && ! "$PYTHON_BIN" -c 'import tkinter' >/dev/null 2>&1; then
    if [[ "$DRY_RUN" == "1" ]]; then
        note 'Would install python-tk@3.14 with Homebrew.'
    else
        note 'Installing the Python Tk package with Homebrew.'
        "$BREW" install python-tk@3.14
        "$PYTHON_BIN" -c 'import tkinter' >/dev/null 2>&1 || die 'Python Tk support is still unavailable after installing python-tk@3.14.'
    fi
elif [[ -z "$PYTHON_BIN" && "$DRY_RUN" == "1" ]]; then
    note 'Would check Python Tk support and install python-tk@3.14 if needed.'
fi

VENV_PYTHON="$VENV_DIR/bin/python"
if [[ -e "$VENV_DIR" && ! -x "$VENV_PYTHON" ]]; then
    die "Found $VENV_DIR without its Python executable; move it aside or remove it, then rerun."
fi

if [[ ! -x "$VENV_PYTHON" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        note "Would create the virtual environment at $VENV_DIR."
    else
        note "Creating the virtual environment at $VENV_DIR."
        "$PYTHON_BIN" -m venv "$VENV_DIR"
    fi
fi

if [[ -x "$VENV_PYTHON" ]]; then
    VENV_VERSION="$("$VENV_PYTHON" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    [[ "$VENV_VERSION" == "3.14" ]] || die "$VENV_DIR uses Python $VENV_VERSION; move it aside or remove it, then rerun."

    VENV_ARCH="$("$VENV_PYTHON" -c 'import platform; print(platform.machine())')"
    if [[ "$IS_APPLE_SILICON" == "1" && "$VENV_ARCH" != "arm64" ]]; then
        die "$VENV_DIR uses $VENV_ARCH Python; move it aside or remove it, then rerun from a native arm64 shell."
    fi
fi

REQUIREMENTS_HASH="$(shasum -a 256 "$PROJECT_ROOT/requirements.txt" | cut -d ' ' -f 1)"
REQUIREMENTS_STAMP="$VENV_DIR/.requirements.sha256"
NEEDS_INSTALL=1
if [[ -r "$REQUIREMENTS_STAMP" && "$(<"$REQUIREMENTS_STAMP")" == "$REQUIREMENTS_HASH" ]]; then
    NEEDS_INSTALL=0
fi

if [[ "$NEEDS_INSTALL" == "1" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        note 'Would install or refresh Python dependencies from requirements.txt.'
    else
        note 'Installing Python dependencies from requirements.txt.'
        PIP_NO_INPUT=1 PIP_DISABLE_PIP_VERSION_CHECK=1 \
            "$VENV_PYTHON" -m pip install --no-input -r "$PROJECT_ROOT/requirements.txt"
        printf '%s\n' "$REQUIREMENTS_HASH" > "$REQUIREMENTS_STAMP.tmp"
        mv -f "$REQUIREMENTS_STAMP.tmp" "$REQUIREMENTS_STAMP"
    fi
fi

HAS_PROVIDER_OVERRIDE=0
for arg in "$@"; do
    case "$arg" in
        --execution-provider|--execution-provider=*) HAS_PROVIDER_OVERRIDE=1 ;;
    esac
done

LAUNCH_ARGS=()
if [[ "$IS_APPLE_SILICON" == "1" && "$HAS_PROVIDER_OVERRIDE" == "0" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
        LAUNCH_ARGS+=(--execution-provider coreml)
        note 'Apple Silicon launch will prefer CoreML; the app can fall back if the provider is unavailable.'
    elif "$VENV_PYTHON" -c 'import onnxruntime; assert "CoreMLExecutionProvider" in onnxruntime.get_available_providers()' >/dev/null 2>&1; then
        LAUNCH_ARGS+=(--execution-provider coreml)
        note 'Using the CoreML execution provider on Apple Silicon.'
    else
        note 'CoreML is unavailable; letting the app choose its best available provider.'
    fi
fi

if [[ "$DRY_RUN" == "1" ]]; then
    if [[ -x "$VENV_PYTHON" ]]; then
        COMMAND_PYTHON="$VENV_PYTHON"
    else
        COMMAND_PYTHON="$VENV_DIR/bin/python (after setup)"
    fi
    printf '[launcher] Would run:'
    printf ' %q' "$COMMAND_PYTHON" "$PROJECT_ROOT/run.py" "${LAUNCH_ARGS[@]}" "$@"
    printf '\n'
    exit 0
fi

exec "$VENV_PYTHON" "$PROJECT_ROOT/run.py" "${LAUNCH_ARGS[@]}" "$@"
