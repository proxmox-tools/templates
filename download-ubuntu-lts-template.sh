#!/usr/bin/env bash

# Ubuntu LTS Container Template Download Script
# Downloads the latest LTS Ubuntu container template on Proxmox server
# and manages the template cache

set -Eeuo pipefail

readonly SCRIPT_DIR
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly BASE_DIR="${SCRIPT_DIR}/.."
readonly LOG_DIR="${BASE_DIR}/logs"
readonly LOG_FILE="${LOG_DIR}/template-download.log"

# Create logs directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Logging functions
function log_info() {
    echo -e " \e[1;36m➤\e[0m $1" | tee -a "$LOG_FILE"
}

function log_ok() {
    echo -e " \e[1;32m✔\e[0m $1" | tee -a "$LOG_FILE"
}

function log_error() {
    echo -e " \e[1;31m✖\e[0m $1" | tee -a "$LOG_FILE"
}

function log_warn() {
    echo -e " \e[1;33m⚠\e[0m $1" | tee -a "$LOG_FILE"
}

# Error handling
function error_handler() {
    local line_no=$1
    local exit_code=$2
    log_error "Script failed at line $line_no with exit code $exit_code"
    exit "$exit_code"
}

trap 'error_handler $LINENO $?' ERR

function load_environment() {
    local env_file="${BASE_DIR}/.env"

    if [[ ! -f "$env_file" ]]; then
        log_error "Environment file not found: $env_file"
        log_info "Please copy .env.example to .env and configure your settings"
        exit 1
    fi

    # Load environment variables
    set -a  # automatically export all variables
    # shellcheck source=/dev/null
    source "$env_file"
    set +a

    # Validate required variables
    local required_vars=(
        "PROXMOX_HOST"
        "PROXMOX_USER"
    )

    for var in "${required_vars[@]}"; do
        if [[ -z "${!var:-}" ]]; then
            log_error "Required environment variable not set: $var"
            exit 1
        fi
    done

    log_ok "Environment configuration loaded and validated"
}

function validate_ssh_key() {
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        local key_path="${PROXMOX_SSH_KEY_PATH/#\~/$HOME}"
        
        if [[ ! -f "$key_path" ]]; then
            log_error "SSH key file not found"
            exit 1
        fi
        
        # Check file permissions (should be 600 or 400)
        local perms
        perms=$(stat -c "%a" "$key_path" 2>/dev/null)
        if [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
            log_error "SSH key file has insecure permissions ($perms). Should be 600 or 400"
            log_info "Fix with: chmod 600 $key_path"
            exit 1
        fi
        
        # Basic SSH key format validation
        if ! ssh-keygen -l -f "$key_path" >/dev/null 2>&1; then
            log_error "SSH key file appears to be invalid or corrupted"
            exit 1
        fi
        
        log_ok "SSH key validation passed"
    fi
}

function validate_ssh_connection() {
    log_info "Validating SSH connection to Proxmox server..."

    validate_ssh_key

    local ssh_opts="-o ConnectTimeout=10 -o BatchMode=yes"
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        ssh_opts+=" -i ${PROXMOX_SSH_KEY_PATH}"
    fi

    if ! ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "pveversion" >/dev/null 2>&1; then
        log_error "Cannot connect to Proxmox server"
        log_info "Please ensure:"
        log_info "  - SSH key is properly configured"
        log_info "  - Proxmox server is accessible"
        log_info "  - User has appropriate permissions"
        exit 1
    fi

    log_ok "SSH connection to Proxmox server validated"
}

function get_latest_ubuntu_lts() {
    log_info "Fetching latest Ubuntu LTS template information..."

    local ssh_opts=""
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        ssh_opts="-i ${PROXMOX_SSH_KEY_PATH}"
    fi

    # Get available templates from Proxmox template repository
    local available_templates
    # shellcheck disable=SC2029 # Variables intentionally expand on client side
    available_templates=$(ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "pveam available --section system | grep -E 'ubuntu.*standard.*amd64' | grep -E '(20\.04|22\.04|24\.04)'" 2>/dev/null || echo "")

    if [[ -z "$available_templates" ]]; then
        log_error "No Ubuntu LTS templates found in repository"
        log_info "Updating template list..."
        # shellcheck disable=SC2029 # Variables intentionally expand on client side
        ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "pveam update" 2>/dev/null || true
        # shellcheck disable=SC2029 # Variables intentionally expand on client side
        available_templates=$(ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "pveam available --section system | grep -E 'ubuntu.*standard.*amd64' | grep -E '(20\.04|22\.04|24\.04)'" 2>/dev/null || echo "")
    fi

    if [[ -z "$available_templates" ]]; then
        log_error "Still no Ubuntu LTS templates found after update"
        exit 1
    fi

    # Find the latest LTS version (24.04, then 22.04, then 20.04)
    local latest_template=""
    
    # Try to find Ubuntu 24.04 first (latest LTS as of 2024)
    latest_template=$(echo "$available_templates" | grep "24\.04" | head -n1 | awk '{print $2}' || echo "")
    
    if [[ -z "$latest_template" ]]; then
        # Fall back to 22.04
        latest_template=$(echo "$available_templates" | grep "22\.04" | head -n1 | awk '{print $2}' || echo "")
    fi
    
    if [[ -z "$latest_template" ]]; then
        # Fall back to 20.04
        latest_template=$(echo "$available_templates" | grep "20\.04" | head -n1 | awk '{print $2}' || echo "")
    fi

    if [[ -z "$latest_template" ]]; then
        log_error "Could not determine latest Ubuntu LTS template"
        log_info "Available templates:"
        echo "$available_templates"
        exit 1
    fi

    log_ok "Latest Ubuntu LTS template identified: $latest_template"
    echo "$latest_template"
}

function check_existing_template() {
    local template="$1"
    
    local ssh_opts=""
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        ssh_opts="-i ${PROXMOX_SSH_KEY_PATH}"
    fi

    log_info "Checking if template already exists..."
    
    # Check if template is already downloaded
    # shellcheck disable=SC2029 # Variables intentionally expand on client side
    if ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f /var/lib/vz/template/cache/$template" 2>/dev/null; then
        log_warn "Template already exists: $template"
        
        # Get file size and modification time
        local template_info
        # shellcheck disable=SC2029 # Variables intentionally expand on client side
        template_info=$(ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "ls -lh /var/lib/vz/template/cache/$template" 2>/dev/null || echo "")
        
        if [[ -n "$template_info" ]]; then
            log_info "Existing template details: $template_info"
        fi
        
        return 0
    else
        log_info "Template not found in cache, will download"
        return 1
    fi
}

function download_template() {
    local template="$1"
    
    local ssh_opts=""
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        ssh_opts="-i ${PROXMOX_SSH_KEY_PATH}"
    fi

    log_info "Downloading Ubuntu LTS template: $template"
    log_info "This may take several minutes depending on network speed..."

    # Download the template
    # shellcheck disable=SC2029 # Variables intentionally expand on client side
    if ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "pveam download local $template" 2>&1 | tee -a "$LOG_FILE"; then
        log_ok "Template downloaded successfully: $template"
    else
        log_error "Failed to download template: $template"
        exit 1
    fi

    # Verify the download
    # shellcheck disable=SC2029 # Variables intentionally expand on client side
    if ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "test -f /var/lib/vz/template/cache/$template" 2>/dev/null; then
        log_ok "Template download verified"
        
        # Show template size
        local template_size
        # shellcheck disable=SC2029 # Variables intentionally expand on client side
        template_size=$(ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "ls -lh /var/lib/vz/template/cache/$template | awk '{print \$5}'" 2>/dev/null || echo "unknown")
        log_info "Template size: $template_size"
    else
        log_error "Template verification failed"
        exit 1
    fi
}

function list_all_templates() {
    local ssh_opts=""
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        ssh_opts="-i ${PROXMOX_SSH_KEY_PATH}"
    fi

    log_info "Current template cache contents:"
    # shellcheck disable=SC2029 # Variables intentionally expand on client side
    ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "ls -lh /var/lib/vz/template/cache/ | grep -E '\.(tar\.zst|tar\.xz|tar\.gz)$'" 2>/dev/null || log_warn "No templates found in cache"
}

function cleanup_old_templates() {
    if [[ "${CLEANUP_OLD_TEMPLATES:-false}" != "true" ]]; then
        log_info "Skipping cleanup of old templates (CLEANUP_OLD_TEMPLATES=false)"
        return
    fi

    local ssh_opts=""
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        ssh_opts="-i ${PROXMOX_SSH_KEY_PATH}"
    fi

    log_info "Cleaning up old Ubuntu templates..."

    # Find old Ubuntu templates (keep only the latest downloaded one)
    local old_templates
    # shellcheck disable=SC2029 # Variables intentionally expand on client side
    old_templates=$(ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "ls -t /var/lib/vz/template/cache/ubuntu-*-standard_*_amd64.tar.* 2>/dev/null | tail -n +2" 2>/dev/null || echo "")

    if [[ -n "$old_templates" ]]; then
        log_info "Found old templates to clean up:"
        echo "$old_templates" | while read -r template; do
            log_info "  $(basename "$template")"
        done

        # Remove old templates
        echo "$old_templates" | while read -r template; do
            local template_name
            template_name=$(basename "$template")
            log_info "Removing old template: $template_name"
            # shellcheck disable=SC2029 # Variables intentionally expand on client side
            ssh $ssh_opts "${PROXMOX_USER}@${PROXMOX_HOST}" "rm -f '$template'" 2>/dev/null || log_warn "Failed to remove $template_name"
        done

        log_ok "Old template cleanup completed"
    else
        log_info "No old templates found to clean up"
    fi
}

function display_completion_message() {
    local template="$1"

    log_ok "Ubuntu LTS template download completed successfully!"
    echo
    log_info "Template Details:"
    log_info "  Template Name: $template"
    log_info "  Location: /var/lib/vz/template/cache/$template"
    echo
    log_info "Usage:"
    log_info "  Create container: pct create VMID /var/lib/vz/template/cache/$template"
    log_info "  List templates: pveam list local"
    echo
    log_info "Next Steps:"
    log_info "  - Use this template to create LXC containers"
    log_info "  - Template is ready for deployment scripts"
    echo
}

function main() {
    echo "📦 Ubuntu LTS Template Downloader"
    echo "================================="
    echo

    load_environment
    validate_ssh_connection

    local latest_template
    latest_template=$(get_latest_ubuntu_lts)

    if check_existing_template "$latest_template"; then
        if [[ "${FORCE_DOWNLOAD:-false}" == "true" ]]; then
            log_info "Forcing re-download due to FORCE_DOWNLOAD=true"
            download_template "$latest_template"
        else
            log_info "Template already exists. Use FORCE_DOWNLOAD=true to re-download"
        fi
    else
        download_template "$latest_template"
    fi

    cleanup_old_templates
    list_all_templates
    display_completion_message "$latest_template"
}

# Prevent script from being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
else
    log_error "This script must be executed directly, not sourced"
    exit 1
fi