#!/bin/bash

source /venv/main/bin/activate
FORGE_DIR=${WORKSPACE}/stable-diffusion-webui-forge

# Packages are installed after nodes so we can fix them...

APT_PACKAGES=(
    #"package-1"
    #"package-2"
)

EXTENSIONS=(
    "https://github.com/Bing-su/adetailer"
    "https://github.com/BlafKing/sd-civitai-browser-plus" 
)

PIP_PACKAGES=(

)

CHECKPOINT_MODELS=(
    "https://civitai.com/api/download/models/1500882"
)

UNET_MODELS=(
)

LORA_MODELS=(
    "https://civitai.com/api/download/models/1851199"
    "https://civitai.com/api/download/models/1055293"
    "https://civitai.com/api/download/models/691541"
)

VAE_MODELS=(
)

ESRGAN_MODELS=(
)

CONTROLNET_MODELS=(
)

TEXTUAL_INVERSION_MODELS=(
    "https://civitai.com/api/download/models/1591915"   # replace with your link
)


### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

function provisioning_start() {
    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_extensions
    provisioning_get_pip_packages
    # --- Checkpoints -----------------------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/Stable-diffusion" \
        "${CHECKPOINT_MODELS[@]}"

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
    
    # --- ControlNet ------------------------------------------------------------
    provisioning_get_files \
        "${FORGE_DIR}/models/ControlNet" \
        "${CONTROLNET_MODELS[@]}"

    # Avoid git errors because we run as root but files are owned by 'user'
    export GIT_CONFIG_GLOBAL=/tmp/temporary-git-config
    git config --file $GIT_CONFIG_GLOBAL --add safe.directory '*'
    
    # Start and exit because webui will probably require a restart
    cd "${FORGE_DIR}"
    LD_PRELOAD=libtcmalloc_minimal.so.4 \
        python launch.py \
            --skip-python-version-check \
            --no-download-sd-model \
            --do-not-download-clip \
            --no-half \
            --port 11404 \
            --exit

    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if [[ -n $APT_PACKAGES ]]; then
            sudo $APT_INSTALL ${APT_PACKAGES[@]}
    fi
}

function provisioning_get_pip_packages() {
    if [[ -n $PIP_PACKAGES ]]; then
            pip install --no-cache-dir ${PIP_PACKAGES[@]}
    fi
}

function provisioning_get_extensions() {
    for repo in "${EXTENSIONS[@]}"; do
        dir="${repo##*/}"
        path="${FORGE_DIR}/extensions/${dir}"
        if [[ ! -d $path ]]; then
            printf "Downloading extension: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
        fi
    done
}

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 1; fi
    
    dir="$1"
    mkdir -p "$dir"
    shift
    arr=("$@")
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete:  Application will start now\n\n"
}

function provisioning_has_valid_hf_token() {
    [[ -n "$HF_TOKEN" ]] || return 1
    url="https://huggingface.co/api/whoami-v2"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

function provisioning_has_valid_civitai_token() {
    [[ -n "$CIVITAI_TOKEN" ]] || return 1
    url="https://civitai.com/api/v1/models?hidden=1&limit=1"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

function provisioning_download() {
    local url="$1" dir="$2" auth=""
    [[ -n $HF_TOKEN      && $url =~ huggingface\.co ]] && auth=$HF_TOKEN
    [[ -n $CIVITAI_TOKEN && $url =~ civitai\.com     ]] && auth=$CIVITAI_TOKEN

    echo "→ $url  (${auth:+with token})"

    # ----------- the only line that really had to change ----------- #
    wget --header="Authorization: Bearer $auth" -qnc --content-disposition \
     --show-progress -e dotbytes="${3:-4M}" -P "$dir" "$url"
}

# Allow user to disable provisioning if they started with a script they didn't want
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
