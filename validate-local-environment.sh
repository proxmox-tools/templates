#!/usr/bin/env bash

# Local Environment Validation Script
# Validates local dependencies and environment before running Proxmox template scripts

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

function log_info() {
    echo -e " \e[1;36m➤\e[0m $1"
}

function log_ok() {
    echo -e " \e[1;32m✔\e[0m $1"
}

function log_error() {
    echo -e " \e[1;31m✖\e[0m $1"
}

function log_warn() {
    echo -e " \e[1;33m⚠\e[0m $1"
}

function check_required_commands() {
    log_info "Checking required system commands..."
    
    local required_commands=(
        "ssh"
        "ssh-keygen"
        "stat"
        "grep"
        "awk"
        "head"
        "tail"
    )
    
    local missing_commands=()
    
    for cmd in "${required_commands[@]}"; do
        if command -v "$cmd" >/dev/null 2>&1; then
            log_ok "Command available: $cmd"
        else
            log_error "Command missing: $cmd"
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        log_error "Missing required commands: ${missing_commands[*]}"
        return 1
    fi
    
    log_ok "All required commands are available"
    return 0
}

function validate_environment_file() {
    log_info "Validating environment configuration..."
    
    local env_file=""
    
    # Check for .env in script dir first, then parent dir
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        env_file="${SCRIPT_DIR}/.env"
        log_ok "Found .env file in script directory"
    elif [[ -f "${SCRIPT_DIR}/../.env" ]]; then
        env_file="${SCRIPT_DIR}/../.env"
        log_ok "Found .env file in parent directory"
    else
        log_warn ".env file not found in script directory or parent directory"
        log_info "Create a .env file with your Proxmox configuration"
        return 1
    fi
    
    # Check required variables
    local required_vars=(
        "PROXMOX_HOST"
        "PROXMOX_USER"
    )
    
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if grep -q "^${var}=" "$env_file" && [[ -n "$(grep "^${var}=" "$env_file" | cut -d'=' -f2-)" ]]; then
            log_ok "Environment variable set: $var"
        else
            log_error "Environment variable missing or empty: $var"
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_error "Missing or empty environment variables: ${missing_vars[*]}"
        return 1
    fi
    
    # Load environment for SSH key validation
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    
    # Check SSH key if specified
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        validate_ssh_key "$PROXMOX_SSH_KEY_PATH"
    else
        log_info "No SSH key path specified (will use default SSH agent/keys)"
    fi
    
    log_ok "Environment validation passed"
    return 0
}

function validate_ssh_key() {
    local key_path="$1"
    local expanded_path="${key_path/#\~/$HOME}"
    
    log_info "Validating SSH key: $key_path"
    
    if [[ ! -f "$expanded_path" ]]; then
        log_error "SSH key file not found: $expanded_path"
        return 1
    fi
    
    # Check file permissions
    local perms
    perms=$(stat -c "%a" "$expanded_path" 2>/dev/null)
    if [[ "$perms" != "600" ]] && [[ "$perms" != "400" ]]; then
        log_error "SSH key has insecure permissions ($perms). Should be 600 or 400"
        log_info "Fix with: chmod 600 $expanded_path"
        return 1
    fi
    
    log_ok "SSH key permissions are secure ($perms)"
    
    # Validate SSH key format
    if ! ssh-keygen -l -f "$expanded_path" >/dev/null 2>&1; then
        log_error "SSH key appears to be invalid or corrupted"
        return 1
    fi
    
    log_ok "SSH key validation passed"
    return 0
}

function test_proxmox_connectivity() {
    log_info "Testing Proxmox server connectivity..."
    
    # Find .env file
    local env_file=""
    if [[ -f "${SCRIPT_DIR}/.env" ]]; then
        env_file="${SCRIPT_DIR}/.env"
    elif [[ -f "${SCRIPT_DIR}/../.env" ]]; then
        env_file="${SCRIPT_DIR}/../.env"
    else
        log_warn "Cannot test connectivity - .env file not found"
        return 1
    fi
    
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a
    
    local ssh_opts=(-o ConnectTimeout=10 -o BatchMode=yes)
    if [[ -n "${PROXMOX_SSH_KEY_PATH:-}" ]]; then
        ssh_opts+=(-i "${PROXMOX_SSH_KEY_PATH}")
    fi
    
    if ssh "${ssh_opts[@]}" "${PROXMOX_USER}@${PROXMOX_HOST}" "pveversion" >/dev/null 2>&1; then
        log_ok "Successfully connected to Proxmox server"
        return 0
    else
        log_error "Cannot connect to Proxmox server"
        log_info "Check:"
        log_info "  - Network connectivity to ${PROXMOX_HOST}"
        log_info "  - SSH key configuration"
        log_info "  - User permissions on Proxmox"
        return 1
    fi
}

function main() {
    echo "🔍 Local Environment Validation"
    echo "==============================="
    echo
    
    local validation_passed=true
    
    # Run all validation checks
    if ! check_required_commands; then
        validation_passed=false
    fi
    
    echo
    
    if ! validate_environment_file; then
        validation_passed=false
    fi
    
    echo
    
    if ! test_proxmox_connectivity; then
        validation_passed=false
    fi
    
    echo
    
    if [[ "$validation_passed" == "true" ]]; then
        log_ok "All validations passed! Environment is ready."
        echo
        log_info "You can now run the template download script:"
        log_info "  ./download-ubuntu-lts-template.sh"
    else
        log_error "Some validations failed. Please fix the issues above."
        exit 1
    fi
}

# Prevent script from being sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
else
    log_error "This script must be executed directly, not sourced"
    exit 1
fi