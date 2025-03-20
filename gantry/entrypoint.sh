#!/usr/bin/env bash

set -eo pipefail

# Debug flags for better diagnostics
echo "[GANTRY] Starting with environment variables:"
echo "NO_CONDA: ${NO_CONDA}"
echo "NO_PYTHON: ${NO_PYTHON}"
echo "GITHUB_REPO: ${GITHUB_REPO}"
echo "GIT_REF: ${GIT_REF}"
echo "GITHUB_TOKEN: ${GITHUB_TOKEN:+<redacted>}"

# Ensure we have all the environment variables we need.
for env_var in GITHUB_REPO GIT_REF; do
    if [[ -z "${!env_var}" ]]; then
        echo >&2 "error: required environment variable ${env_var} is empty"
        exit 1
    fi
done

# Function to check for conda, install it if needed.
function ensure_conda {
    if ! command -v conda &> /dev/null; then
        # Skip if NO_CONDA is set
        if [[ -n "$NO_CONDA" ]]; then
            echo "[GANTRY] Skipping conda installation as NO_CONDA is set"
            return 0
        fi
        
        echo "[GANTRY] Installing conda..."
        curl -fsSL -o ~/miniconda.sh -O  https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh
        chmod +x ~/miniconda.sh
        ~/miniconda.sh -b -p /opt/conda
        rm ~/miniconda.sh
        export PATH="/opt/conda/bin:$PATH"
    fi

    # Initialize conda for bash only if we're using conda
    if [[ -z "$NO_CONDA" ]]; then
        # See https://stackoverflow.com/a/58081608/4151392
        eval "$(command conda 'shell.bash' 'hook' 2> /dev/null)"
    fi
}

# Setup git authentication with token
function setup_git_auth {
    if [[ -n "$GITHUB_TOKEN" ]]; then
        echo "[GANTRY] Setting up git authentication using GitHub token"
        # Configure git to use the token for authentication
        git config --global credential.helper store
        echo "https://oauth2:${GITHUB_TOKEN}@github.com" > ~/.git-credentials
        # Set basic git config if not present
        git config --global --get user.name >/dev/null || git config --global user.name "wisdomikezogwo"
        git config --global --get user.email >/dev/null || git config --global user.email "wisdomikezogwo@gmail.com"
        return 0
    else
        echo "[GANTRY] No GitHub token provided for authentication"
        return 1
    fi
}

# Install GitHub CLI if needed and not skipping conda
if [[ -n "$GITHUB_TOKEN" ]]; then
    echo "
########################################
# [GANTRY] Installing prerequisites... #
########################################
"
    if ! command -v gh &> /dev/null; then
        if [[ -n "$NO_CONDA" ]]; then
            echo "[GANTRY] NO_CONDA is set, skipping GitHub CLI installation"
            setup_git_auth
        else
            ensure_conda
            # Install GitHub CLI
            conda install -y gh --channel conda-forge
            
            # Configure git to use GitHub CLI as a credential helper
            if command -v gh &> /dev/null; then
                gh auth setup-git
            else
                setup_git_auth
            fi
        fi
    else
        # GitHub CLI is already installed
        gh auth setup-git
    fi
else
    # No GitHub token, try to proceed with public repo
    echo "[GANTRY] No GitHub token provided, assuming public repository"
fi

echo "
###################################
# [GANTRY] Cloning source code... #
###################################
"

# shellcheck disable=SC2296
mkdir -p "${{ RUNTIME_DIR }}"
# shellcheck disable=SC2296
cd "${{ RUNTIME_DIR }}"

# `git clone` might occasionally fail, so we retry a couple times.
attempts=1
until [ "$attempts" -eq 5 ]
do
    # Try cloning with GitHub CLI if available
    if [[ -n "$GITHUB_TOKEN" ]] && command -v gh &> /dev/null; then
        echo "[GANTRY] Cloning repository using GitHub CLI"
        gh repo clone "$GITHUB_REPO" . && break
    # Otherwise try direct git clone with credentials already set up
    elif [[ -n "$GITHUB_TOKEN" ]]; then
        echo "[GANTRY] Cloning repository using git with token authentication"
        git clone "https://github.com/$GITHUB_REPO" . && break
    # Last resort - public repo without auth
    else
        echo "[GANTRY] Attempting to clone public repository"
        git clone "https://github.com/$GITHUB_REPO" . && break
    fi
    
    echo "[GANTRY] Clone attempt $attempts failed, retrying..."
    attempts=$((attempts+1)) 
    sleep 10
done

if [ $attempts -eq 5 ]; then
  echo >&2 "error: failed to clone $GITHUB_REPO after $attempts tries"
  exit 1
fi

echo "[GANTRY] Checking out ref: $GIT_REF"
git checkout "$GIT_REF"

echo "[GANTRY] Updating git submodules"
git submodule update --init --recursive

# Skip Python environment setup if NO_PYTHON is set
if [[ -z "$NO_PYTHON" ]]; then
    echo "
###################################
# [GANTRY] Building Python env... #
###################################
"
    
    if [[ -z "$VENV_NAME" ]]; then
        VENV_NAME=venv
    fi
    if [[ -z "$CONDA_ENV_FILE" ]]; then
        # shellcheck disable=SC2296
        CONDA_ENV_FILE="${{ CONDA_ENV_FILE }}"
    fi
    if [[ -z "$PIP_REQUIREMENTS_FILE" ]]; then
        # shellcheck disable=SC2296
        PIP_REQUIREMENTS_FILE="${{ PIP_REQUIREMENTS_FILE }}"
    fi
    
    if [[ -z "$NO_CONDA" ]]; then
        ensure_conda

        # Check if VENV_NAME is a path. If so, it should exist.
        if [[ "$VENV_NAME" == */* ]]; then
            if [[ ! -d "$VENV_NAME" ]]; then
                echo >&2 "error: venv '$VENV_NAME' looks like a path but it doesn't exist"
                exit 1
            fi
        fi
        
        if conda activate "$VENV_NAME" &> /dev/null; then
            echo "[GANTRY] Using existing conda environment '$VENV_NAME'"
            # The virtual environment already exists. Possibly update it based on an environment file.
            if [[ -f "$CONDA_ENV_FILE" ]]; then
                echo "[GANTRY] Updating environment from conda env file '$CONDA_ENV_FILE'..."
                conda env update -f "$CONDA_ENV_FILE"
            fi
        else
            # The virtual environment doesn't exist yet. Create it.
            if [[ -f "$CONDA_ENV_FILE" ]]; then
                # Create from the environment file.
                echo "[GANTRY] Initializing environment from conda env file '$CONDA_ENV_FILE'..."
                conda env create -n "$VENV_NAME" -f "$CONDA_ENV_FILE" 
            elif [[ -z "$PYTHON_VERSION" ]]; then
                # Create a new empty environment with the whatever the default Python version is.
                echo "[GANTRY] Initializing environment with default Python version..."
                conda create -y -n "$VENV_NAME" pip
            else
                # Create a new empty environment with the specific Python version.
                echo "[GANTRY] Initializing environment with Python $PYTHON_VERSION..."
                conda create -y -n "$VENV_NAME" "python=$PYTHON_VERSION" pip
            fi
            conda activate "$VENV_NAME"
        fi
    else
        echo "[GANTRY] Skipping conda environment setup as NO_CONDA is set"
    fi
    
    if [[ -z "$INSTALL_CMD" ]]; then
        # Check for a 'requirements.txt' and/or 'setup.py/pyproject.toml/setup.cfg' file.
        if { [[ -f 'setup.py' ]] || [[ -f 'pyproject.toml' ]] || [[ -f 'setup.cfg' ]]; } && [[ -f "$PIP_REQUIREMENTS_FILE" ]]; then
            echo "[GANTRY] Installing local project and packages from '$PIP_REQUIREMENTS_FILE'..."
            pip install . -r "$PIP_REQUIREMENTS_FILE"
        elif [[ -f 'setup.py' ]] || [[ -f 'pyproject.toml' ]] || [[ -f 'setup.cfg' ]]; then
            echo "[GANTRY] Installing local project..."
            pip install .
        elif [[ -f "$PIP_REQUIREMENTS_FILE" ]]; then
            echo "[GANTRY] Installing packages from '$PIP_REQUIREMENTS_FILE'..."
            pip install -r "$PIP_REQUIREMENTS_FILE"
        fi
    else
        echo "[GANTRY] Installing packages with given command: $INSTALL_CMD"
        eval "$INSTALL_CMD"
    fi
    
    if [[ -z "$PYTHONPATH" ]]; then
        PYTHONPATH="$(pwd)"
    else
        PYTHONPATH="${PYTHONPATH}:$(pwd)"
    fi
    export PYTHONPATH
    
    # Create directory for results.
    # shellcheck disable=SC2296
    mkdir -p "${{ RESULTS_DIR }}/.gantry"
    
    
    echo "
#############################
# [GANTRY] Environment info #
#############################
"
    
    echo "Using $(python --version) from $(which python)"
    echo "Packages:"
    if which sed >/dev/null; then
        pip freeze | sed 's/^/- /'
    else
        pip freeze
    fi
else
    echo "[GANTRY] Skipping Python environment setup as NO_PYTHON is set"
    
    # Still create results directory even if skipping Python setup
    # shellcheck disable=SC2296
    mkdir -p "${{ RESULTS_DIR }}/.gantry"
fi

echo "
#############################
# [GANTRY] Setup complete ✓ #
#############################
"

# Execute the arguments to this script as commands themselves.
# shellcheck disable=SC2296
exec "$@" 2>&1