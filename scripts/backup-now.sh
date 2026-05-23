#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================
# Constants
# ==============================
readonly SCRIPT_NAME="$(basename "$0")"
readonly VERSION="1.0.0"

# ==============================
# Colors & Formatting
# ==============================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

CHECK="✔"
CROSS="✖"
ARROW="➜"

# ==============================
# Logging Functions
# ==============================
log_section() {
    echo -e "\n${BOLD}----------------------------------------${NC}"
    echo -e " ${BOLD}$*${NC}"
    echo -e "${BOLD}----------------------------------------${NC}\n"
}
log_info()    { echo -e "${BLUE}[INFO]${NC}    $*"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} ${CHECK} $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    ${ARROW} $*"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   ${CROSS} $*" >&2; }

# ==============================
# Error Handler
# ==============================
error_handler() {
    local exit_code=$?
    log_error "An error occurred on line $1 (Exit Code: ${exit_code})"
    exit "${exit_code}"
}
trap 'error_handler $LINENO' ERR

# ==============================
# Help and Usage
# ==============================
usage() {
    cat << EOF
${SCRIPT_NAME} v${VERSION}
Triggers a pgBackRest backup and reports repository status.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -t, --type TYPE      Backup type: 'full', 'diff', or 'incr' (Default: 'incr')
  -s, --stanza NAME    Stanza name (Default: 'main')
  -h, --help           Show this help message and exit
  -v, --version        Show version info

Examples:
  ./${SCRIPT_NAME} --type=full
  ./${SCRIPT_NAME} -t diff -s main
EOF
}

# ==============================
# Helper Functions
# ==============================
require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "$1 is required but not installed."
        exit 3
    }
}

check_user() {
    # pgBackRest must be run as the postgres user to maintain correct permissions.
    # If run as root, we will warn the user and suggest running as postgres.
    local current_user
    current_user=$(whoami)
    
    if [[ "${current_user}" != "postgres" ]]; then
        if [[ $EUID -eq 0 ]]; then
            log_warn "Running as root. Re-executing command as 'postgres' user..."
            exec sudo -u postgres "$0" "$@"
        else
            log_error "This script must be run as the 'postgres' user or as root with sudo."
            exit 2
        fi
    fi
}

# ==============================
# Main Execution Pipeline
# ==============================
main() {
    local backup_type="incr"
    local stanza="main"

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--help)
                usage
                exit 0
                ;;
            -v|--version)
                echo "${SCRIPT_NAME} v${VERSION}"
                exit 0
                ;;
            -t|--type)
                if [[ -z "${2:-}" ]]; then
                    log_error "Backup type missing for option -t/--type"
                    usage
                    exit 2
                fi
                backup_type="$2"
                shift 2
                ;;
            -t=*|--type=*)
                backup_type="${1#*=}"
                shift
                ;;
            -s|--stanza)
                if [[ -z "${2:-}" ]]; then
                    log_error "Stanza name missing for option -s/--stanza"
                    usage
                    exit 2
                fi
                stanza="$2"
                shift 2
                ;;
            -s=*|--stanza=*)
                stanza="${1#*=}"
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    # Validate backup type
    if [[ ! "${backup_type}" =~ ^(full|diff|incr)$ ]]; then
        log_error "Invalid backup type: '${backup_type}'. Must be 'full', 'diff', or 'incr'."
        exit 4
    fi

    # Check execution user and re-run as postgres if needed
    check_user "$@"

    log_section "Triggering pgBackRest Backup"
    
    # Check dependencies
    require_command pgbackrest

    log_info "Target Stanza: ${stanza}"
    log_info "Backup Type  : ${backup_type}"
    
    # 1. Verify stanza exists
    log_info "Checking stanza status..."
    if ! pgbackrest --stanza="${stanza}" info >/dev/null 2>&1; then
        log_error "Stanza '${stanza}' does not exist or has not been initialized."
        exit 4
    fi
    log_success "Stanza ready."

    # 2. Trigger the backup
    log_info "Executing pgBackRest backup (type: ${backup_type})..."
    
    local start_time
    start_time=$(date +%s)

    if ! pgbackrest --stanza="${stanza}" backup --type="${backup_type}"; then
        log_error "Backup failed! Please check logs at /var/log/pgbackrest/${stanza}-backup.log"
        exit 1
    fi
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    log_success "Backup completed in ${duration} seconds."

    # 3. Report repository statistics
    log_section "Repository Information Summary"
    pgbackrest --stanza="${stanza}" info
}

main "$@"
