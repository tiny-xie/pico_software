#!/usr/bin/env bash
set -e

# Check the operating system
OS_NAME=$(uname -s)
OS_VERSION=""

if [[ "$OS_NAME" == "Linux" ]]; then
    if command -v lsb_release &>/dev/null; then
        OS_VERSION=$(lsb_release -rs)
    elif [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_VERSION=$VERSION_ID
    fi
    if [[ "$OS_VERSION" != "22.04" && "$OS_VERSION" != "24.04" ]]; then
        echo "Warning: This script has only been tested on Ubuntu 22.04 and 24.04"
        echo "Your system is running Ubuntu $OS_VERSION."
        read -p "Do you want to continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "Installation cancelled."
            exit 1
        fi
    fi
else
    echo "Unsupported operating system: $OS_NAME"
    exit 1
fi

echo "Operating system check passed: $OS_NAME $OS_VERSION"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

VENV_DIR=".venv"
PYTHON_SPEC=""
USE_MIRRORS=0
GITHUB_PREFIX=""
DEFAULT_PYPI_MIRROR_URL="https://mirrors.aliyun.com/pypi/simple"
DEFAULT_GITHUB_MIRROR_PREFIX="https://ghfast.top/"
ORIGINAL_NO_PROXY="${NO_PROXY:-}"
ORIGINAL_no_proxy="${no_proxy:-}"

print_help() {
    cat <<EOF
Usage: bash setup_uv.sh [options]

Options:
    --venv <path>                  Virtual environment directory (default: .venv).
    --python <version-or-exe>      Python version or executable for uv venv.
    --use-mirror                   Use mirrors for faster downloads.
    -h, --help                     Show this help message and exit.

Environment overrides:
    PYPI_MIRROR_URL                PyPI simple index used by --use-mirror
                                   (default: ${DEFAULT_PYPI_MIRROR_URL}).
    GITHUB_MIRROR_PREFIX           GitHub URL prefix used by --use-mirror
                                   (default: ${DEFAULT_GITHUB_MIRROR_PREFIX}).
EOF
}

setup_mirror() {
    if [[ "$USE_MIRRORS" -eq 1 ]]; then
        local pypi_mirror="${PYPI_MIRROR_URL:-$DEFAULT_PYPI_MIRROR_URL}"
        local github_prefix="${GITHUB_MIRROR_PREFIX:-$DEFAULT_GITHUB_MIRROR_PREFIX}"
        local mirror_no_proxy="mirrors.aliyun.com,pypi.tuna.tsinghua.edu.cn,mirrors.nju.edu.cn,ghfast.top,hf-mirror.com"
        export UV_PYTHON_INSTALL_MIRROR="${github_prefix}https://github.com/astral-sh/python-build-standalone/releases/download"
        export UV_DEFAULT_INDEX="$pypi_mirror"
        export HF_ENDPOINT=https://hf-mirror.com
        export GITHUB_PREFIX="$github_prefix"
        export NO_PROXY="${NO_PROXY:+$NO_PROXY,}${mirror_no_proxy}"
        export no_proxy="${no_proxy:+$no_proxy,}${mirror_no_proxy}"
        echo "[INFO] Using PyPI mirror: $UV_DEFAULT_INDEX"
        echo "[INFO] Using GitHub mirror prefix: $GITHUB_PREFIX"
        git config --global url."${GITHUB_PREFIX}github.com/".insteadOf "https://github.com/"
    fi
}

unset_mirror() {
    if [[ "$USE_MIRRORS" -eq 1 ]]; then
        unset UV_PYTHON_INSTALL_MIRROR
        unset UV_DEFAULT_INDEX
        unset HF_ENDPOINT
        if [[ -n "$ORIGINAL_NO_PROXY" ]]; then
            export NO_PROXY="$ORIGINAL_NO_PROXY"
        else
            unset NO_PROXY
        fi
        if [[ -n "$ORIGINAL_no_proxy" ]]; then
            export no_proxy="$ORIGINAL_no_proxy"
        else
            unset no_proxy
        fi
        git config --global --unset url."${GITHUB_PREFIX}github.com/".insteadOf || true
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --venv)
            if [[ -n "$2" ]]; then
                VENV_DIR="$2"
                shift 2
            else
                echo "Error: --venv requires a path."
                exit 1
            fi
            ;;
        --python)
            if [[ -n "$2" ]]; then
                PYTHON_SPEC="$2"
                shift 2
            else
                echo "Error: --python requires a Python version or executable."
                exit 1
            fi
            ;;
        --use-mirror)
            USE_MIRRORS=1
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Invalid argument: $1"
            print_help
            exit 1
            ;;
    esac
done

setup_mirror
trap unset_mirror EXIT

# Detect the system's default Python version, matching setup_conda.sh behavior.
if [[ -z "$PYTHON_SPEC" ]]; then
    if command -v python3 &>/dev/null; then
        PYTHON_VERSION=$(python3 --version 2>&1)
    elif command -v python &>/dev/null; then
        PYTHON_VERSION=$(python --version 2>&1)
    else
        echo "Python is not installed on this system."
        exit 1
    fi

    echo "The system's default Python version is: $PYTHON_VERSION"
    PYTHON_SPEC=$(echo "$PYTHON_VERSION" | grep -oP '\d+\.\d+')
fi

if ! command -v uv &>/dev/null || ! uv --version &>/dev/null; then
    echo "uv is not available. Installing uv with the official installer..."
    if ! command -v curl &>/dev/null; then
        echo "curl is required to install uv. Please install curl first."
        exit 1
    fi
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi

if ! command -v uv &>/dev/null; then
    echo "uv installation failed or uv is not in PATH."
    exit 1
fi

echo "Using uv: $(uv --version)"

# Create a uv virtual environment. This replaces the conda environment step.
rm -rf "$VENV_DIR"
uv venv --python "$PYTHON_SPEC" "$VENV_DIR"

# Activate the uv environment for all following uv pip installs.
source "$VENV_DIR/bin/activate"
uv pip install --upgrade pip setuptools wheel pybind11

# The upstream XRoboToolkit-PC-Service-Pybind setup script installs pybind11
# through conda in the official conda flow. In a uv/venv environment, expose
# the pip-installed pybind11 CMake package so setup.py can find it.
PYBIND11_CMAKE_PREFIX=$(python -c 'import pathlib, pybind11; print(pathlib.Path(pybind11.get_cmake_dir()).parents[2])')
export CMAKE_PREFIX_PATH="${PYBIND11_CMAKE_PREFIX}${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"

# Install the required packages, following setup_conda.sh --install one-to-one.
rm -rf dependencies
mkdir dependencies
cd dependencies

git clone ${GITHUB_PREFIX}https://github.com/XR-Robotics/XRoboToolkit-PC-Service-Pybind.git
cd XRoboToolkit-PC-Service-Pybind

# Inline the official setup_ubuntu.sh flow, replacing the conda/pip pybind11
# install step with the uv-managed pybind11 prepared above.
mkdir -p tmp
cd tmp
git clone ${GITHUB_PREFIX}https://github.com/XR-Robotics/XRoboToolkit-PC-Service.git
cd XRoboToolkit-PC-Service/RoboticsService/PXREARobotSDK
bash build.sh
cd ../../../..

mkdir -p lib
mkdir -p include
cp tmp/XRoboToolkit-PC-Service/RoboticsService/PXREARobotSDK/PXREARobotSDK.h include/
cp -r tmp/XRoboToolkit-PC-Service/RoboticsService/PXREARobotSDK/nlohmann include/nlohmann/
cp tmp/XRoboToolkit-PC-Service/RoboticsService/PXREARobotSDK/build/libPXREARobotSDK.so lib/

pip uninstall -y xrobotoolkit_sdk
python setup.py install

cd ..
git clone ${GITHUB_PREFIX}https://github.com/zhigenzhao/R5.git
cd R5
git checkout dev/python_pkg
cd py/ARX_R5_python/
uv pip install .

cd ../../../..

uv pip install -e . || { echo "Failed to install xrobotoolkit_teleop with uv"; exit 1; }

echo -e "\n"
echo -e "[INFO] xrobotoolkit_teleop is installed in uv environment '$VENV_DIR'.\n"
echo -e "\t\t1. To activate the environment, run:                source $VENV_DIR/bin/activate"
echo -e "\t\t2. To deactivate the environment, run:              deactivate"
echo -e "\n"
