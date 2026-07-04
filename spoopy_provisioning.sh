#!/bin/bash
set -euo pipefail

source /venv/main/bin/activate

WORKSPACE="${WORKSPACE:-/workspace}"
FORGE_DIR="${FORGE_DIR:-${WORKSPACE}/stable-diffusion-webui-forge}"

# Assumes your Vast image is already Forge Neo, e.g.
# vastai/sd-forge:neo-a90af56-2026-03-23-cuda-12.9

APT_PACKAGES=(
    # "package-1"
    # "package-2"
)

EXTENSIONS=(
    "https://github.com/Bing-su/adetailer"
)

PIP_PACKAGES=(
)

# Format:
# "URL|target_filename"
#
# The part after | is optional, but recommended for Civitai/HF URLs with query strings.

CHECKPOINT_MODELS=(
    # Anima main model / DiT
    "https://civitai.red/api/download/models/2945208?fileId=2824391|anima-base-v1.0.safetensors"
)

TEXT_ENCODER_MODELS=(
    # Anima Qwen text encoder
    "https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors?download=true|qwen_3_06b_base.safetensors"
)

VAE_MODELS=(
    # Qwen VAE, renamed to the Anima/Forge-expected name
    "https://huggingface.co/Anzhc/Qwen2D-VAE/resolve/main/Qwen2D_VAE.safetensors?download=true|qwen_image_vae.safetensors"
)

UNET_MODELS=(
)

LORA_MODELS=(
)

ESRGAN_MODELS=(
)

CONTROLNET_MODELS=(
)

TEXTUAL_INVERSION_MODELS=(
    "https://civitai.com/api/download/models/2121199"
)

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

function provisioning_start() {
    provisioning_print_header

    provisioning_get_apt_packages
    provisioning_get_extensions
    provisioning_get_pip_packages

    # --- Checkpoints / DiT -----------------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/Stable-diffusion" \
        "${CHECKPOINT_MODELS[@]}"

    # --- Extra UNet models, if any ---------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/Stable-diffusion" \
        "${UNET_MODELS[@]}"

    # --- Text Encoders ---------------------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/text_encoder" \
        "${TEXT_ENCODER_MODELS[@]}"

    # --- Textual Inversions / Embeddings ---------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/embeddings" \
        "${TEXTUAL_INVERSION_MODELS[@]}"

    # --- LoRAs -----------------------------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/Lora" \
        "${LORA_MODELS[@]}"

    # --- VAEs ------------------------------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/VAE" \
        "${VAE_MODELS[@]}"

    # --- ESRGAN / Upscalers ----------------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/ESRGAN" \
        "${ESRGAN_MODELS[@]}"

    # --- ControlNet ------------------------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/ControlNet" \
        "${CONTROLNET_MODELS[@]}"

    provisioning_print_model_summary

    # Avoid git errors because provisioning may run as root while files are owned by user
    export GIT_CONFIG_GLOBAL=/tmp/temporary-git-config
    git config --file "$GIT_CONFIG_GLOBAL" --add safe.directory '*'

    # Start and exit once so Forge can finish installing/preparing requirements.
    # Do NOT use --no-half for Anima unless you specifically need it.
    cd "${FORGE_DIR}"

    LAUNCH_CMD=(
        python launch.py
        --skip-python-version-check
        --no-download-sd-model
        --do-not-download-clip
        --port 11404
        --exit
    )

    if ldconfig -p 2>/dev/null | grep -q "libtcmalloc_minimal.so.4"; then
        LD_PRELOAD=libtcmalloc_minimal.so.4 "${LAUNCH_CMD[@]}"
    else
        "${LAUNCH_CMD[@]}"
    fi

    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if (( ${#APT_PACKAGES[@]} == 0 )); then
        return 0
    fi

    if command -v sudo >/dev/null 2>&1; then
        sudo apt-get update
        sudo apt-get install -y "${APT_PACKAGES[@]}"
    else
        apt-get update
        apt-get install -y "${APT_PACKAGES[@]}"
    fi
}

function provisioning_get_pip_packages() {
    if (( ${#PIP_PACKAGES[@]} == 0 )); then
        return 0
    fi

    pip install --no-cache-dir "${PIP_PACKAGES[@]}"
}

function provisioning_get_extensions() {
    mkdir -p "${FORGE_DIR}/extensions"

    for repo in "${EXTENSIONS[@]}"; do
        dir="${repo##*/}"
        dir="${dir%.git}"
        path="${FORGE_DIR}/extensions/${dir}"

        if [[ ! -d "$path" ]]; then
            printf "Downloading extension: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
        else
            printf "Extension already exists: %s\n" "${dir}"
        fi
    done
}

function provisioning_get_files() {
    if (( $# < 2 )); then
        return 0
    fi

    local dir="$1"
    shift
    local arr=("$@")

    if (( ${#arr[@]} == 0 )); then
        return 0
    fi

    mkdir -p "$dir"

    printf "\nDownloading %s file(s) to %s...\n" "${#arr[@]}" "$dir"

    for entry in "${arr[@]}"; do
        provisioning_download "${entry}" "${dir}"
        printf "\n"
    done
}

function provisioning_download() {
    local entry="$1"
    local dir="$2"

    local url=""
    local filename=""

    if [[ "$entry" == *"|"* ]]; then
        url="${entry%%|*}"
        filename="${entry#*|}"
    else
        url="$entry"
        filename="$(basename "${url%%\?*}")"
    fi

    if [[ -z "$filename" || "$filename" == "/" || "$filename" == "." ]]; then
        filename="downloaded_model.safetensors"
    fi

    if [[ ! "$filename" =~ \.(safetensors|ckpt|pt|pth|bin)$ ]]; then
        filename="${filename}.safetensors"
    fi

    local output="${dir}/${filename}"
    local partial="${output}.part"

    if [[ -s "$output" ]]; then
        echo "✓ Already exists: ${output}"
        ls -lh "$output"
        return 0
    fi

    local headers=()

    # Only send HF token to huggingface.co
    if [[ -n "${HF_TOKEN:-}" && "$url" =~ ^https://huggingface\.co/ ]]; then
        headers=(-H "Authorization: Bearer ${HF_TOKEN}")
    fi

    # Only send Civitai token to official civitai.com.
    # Do not send your token to civitai.red or other mirror/proxy domains.
    if [[ -n "${CIVITAI_TOKEN:-}" && "$url" =~ ^https://civitai\.com/ ]]; then
        headers=(-H "Authorization: Bearer ${CIVITAI_TOKEN}")
    fi

    echo "→ ${url}"
    echo "  saving as: ${filename}"

    curl -L "${headers[@]}" \
        --retry 5 \
        --retry-delay 2 \
        --fail \
        -C - \
        -o "$partial" \
        "$url"

    mv -f "$partial" "$output"

    echo "✓ Saved:"
    ls -lh "$output"
}

function provisioning_print_header() {
    printf "\n##############################################\n"
    printf "#                                            #\n"
    printf "#          Provisioning container            #\n"
    printf "#                                            #\n"
    printf "#         This will take some time           #\n"
    printf "#                                            #\n"
    printf "# Your container will be ready on completion #\n"
    printf "#                                            #\n"
    printf "##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete: Application will start now\n\n"
}

function provisioning_print_model_summary() {
    printf "\nDownloaded model summary:\n\n"

    for dir in \
        "${FORGE_DIR}/models/Stable-diffusion" \
        "${FORGE_DIR}/models/text_encoder" \
        "${FORGE_DIR}/models/VAE" \
        "${FORGE_DIR}/models/Lora" \
        "${FORGE_DIR}/embeddings"
    do
        if [[ -d "$dir" ]]; then
            echo "---- $dir"
            find "$dir" -maxdepth 1 -type f -printf "%f\t%k KB\n" | sort || true
            echo
        fi
    done
}

# Allow user to disable provisioning if they started with a script they didn't want
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
