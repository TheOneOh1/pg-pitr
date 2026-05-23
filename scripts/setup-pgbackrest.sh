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
Automates package installation, directory setup, configurations, and stanza initialization for pgBackRest.

Usage:
  ${SCRIPT_NAME} [options]

Options:
  -h, --help       Show this help message and exit
  -v, --version    Show version info
  -n, --non-interactive  Run in non-interactive mode (assumes yes to prompts)

Examples:
  sudo ./${SCRIPT_NAME}
  sudo ./${SCRIPT_NAME} --non-interactive
EOF
}

# ==============================
# Helper Functions
# ==============================
require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "$1 is required but not installed. Please install it first."
        exit 3
    }
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root or with sudo."
        exit 2
    fi
}

# ==============================
# Main Execution Pipeline
# ==============================
main() {
    local non_interactive=false

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
            -n|--non-interactive)
                non_interactive=true
                shift
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 2
                ;;
        esac
    done

    check_root

    log_section "System Check & Environment Verification"

    # 1. Dependency checks
    log_info "Verifying system dependencies..."
    require_command apt
    require_command systemctl

    # 2. Check if we are running in non-interactive or ask for confirmation
    if [[ "${non_interactive}" == false ]]; then
        log_warn "This script will modify system packages, create backup directories, and restart PostgreSQL."
        read -rp "Are you sure you want to proceed? [y/N] " confirmation
        if [[ ! "${confirmation}" =~ ^[yY](es)?$ ]]; then
            log_warn "Installation cancelled by user."
            exit 0
        fi
    fi

    # 3. Install packages
    log_section "[1/6] Installing PostgreSQL & pgBackRest Packages"
    log_info "Updating apt package index..."
    apt-get update -y >/dev/null

    log_info "Installing postgresql, postgresql-client, and pgbackrest..."
    apt-get install -y postgresql postgresql-client pgbackrest >/dev/null
    log_success "Packages installed successfully."

    # Verify versions
    local pgbackrest_ver
    pgbackrest_ver=$(pgbackrest version | awk '{print $2}')
    local psql_ver
    psql_ver=$(psql --version | awk '{print $3}')
    log_info "pgBackRest Version: ${pgbackrest_ver}"
    log_info "PostgreSQL Client Version: ${psql_ver}"

    # 4. Create repository directories
    log_section "[2/6] Configuring Repository Directories"
    local paths=(
        "/var/lib/pgbackrest"
        "/var/log/pgbackrest"
        "/var/spool/pgbackrest"
    )

    for path in "${paths[@]}"; do
        log_info "Creating and configuring permissions for ${path}..."
        mkdir -p "${path}"
        chown -R postgres:postgres "${path}"
        chmod 750 "${path}"
    done
    log_success "Repository directories configured."

    # 5. Detect PostgreSQL details
    log_section "[3/6] Detecting PostgreSQL Environment"
    # Find data directory and postgresql.conf paths dynamically
    local pg_data
    local pg_conf
    local pg_version

    # Attempt to detect via pg_lsclusters (highly reliable on Debian/Ubuntu)
    if command -v pg_lsclusters >/dev/null 2>&1; then
        pg_version=$(pg_lsclusters -h | awk '{print $1}' | head -n 1)
        pg_data=$(pg_lsclusters -h | awk '{print $6}' | head -n 1)
        pg_conf="/etc/postgresql/${pg_version}/main/postgresql.conf"
    else
        # Fallback to defaults
        pg_version="14"
        pg_data="/var/lib/postgresql/${pg_version}/main"
        pg_conf="/etc/postgresql/${pg_version}/main/postgresql.conf"
    fi

    log_info "Detected PostgreSQL Version  : ${pg_version}"
    log_info "Detected Data Directory     : ${pg_data}"
    log_info "Detected Configuration File  : ${pg_conf}"

    if [[ ! -d "${pg_data}" ]]; then
        log_error "PostgreSQL data directory ${pg_data} does not exist. Ensure PostgreSQL cluster is initialized."
        exit 4
    fi

    # 6. Deploy configurations
    log_section "[4/6] Deploying Configuration Files"
    
    # 6.1 Create pgbackrest.conf
    log_info "Writing /etc/pgbackrest.conf..."
    cat > /etc/pgbackrest.conf << EOF
[global]
repo1-path=/var/lib/pgbackrest

# Retention
repo1-retention-full=7
repo1-retention-diff=7

# Performance
start-fast=y
process-max=2
archive-async=y
spool-path=/var/spool/pgbackrest

# Storage optimisation
repo1-bundle=y
repo1-block=y

# Compression
compress-type=zst
compress-level=3

# Logging
log-level-console=info
log-level-file=detail
log-level-stderr=off
log-path=/var/log/pgbackrest

[main]
pg1-path=${pg_data}
pg1-port=5432
EOF
    chown postgres:postgres /etc/pgbackrest.conf
    chmod 640 /etc/pgbackrest.conf
    log_success "/etc/pgbackrest.conf written."

    # 6.2 Configure postgresql.conf WAL archiving
    log_info "Configuring WAL archiving in ${pg_conf}..."
    
    # Remove old settings if they exist to avoid duplication
    sed -i '/# pgBackRest Archive Settings/,$d' "${pg_conf}" || true
    
    # Append the configuration
    cat >> "${pg_conf}" << EOF

# pgBackRest Archive Settings
wal_level = replica
archive_mode = on
archive_command = 'pgbackrest --stanza=main archive-push %p'
archive_timeout = 60
max_wal_senders = 3
EOF
    log_success "${pg_conf} updated."

    # 7. Restart PostgreSQL
    log_section "[5/6] Restarting Services"
    log_info "Restarting PostgreSQL to enable WAL archiving..."
    systemctl restart postgresql
    
    # Wait for readiness
    until sudo -u postgres pg_isready -q; do
        log_info "Waiting for database service to be ready..."
        sleep 2
    done
    log_success "PostgreSQL is running and accepting connections."

    # 8. Create and verify pgBackRest Stanza
    log_section "[6/6] Initializing pgBackRest Stanza"
    log_info "Creating stanza 'main'..."
    if ! sudo -u postgres pgbackrest --stanza=main stanza-create; then
        log_error "Failed to create stanza."
        exit 1
    fi
    log_success "Stanza 'main' created."

    log_info "Validating WAL archiving configuration..."
    if ! sudo -u postgres pgbackrest --stanza=main check; then
        log_error "Validation check failed! Verify archive_command logs."
        exit 1
    fi
    log_success "Stanza validation completed successfully."

    log_section "Installation Completed Successfully!"
    log_info "Next Steps:"
    echo -e "  1. Run your first full backup:  ${GREEN}sudo -u postgres pgbackrest --stanza=main backup --type=full${NC}"
    echo -e "  2. View backup information:     ${GREEN}sudo -u postgres pgbackrest info${NC}"
    echo -e "  3. Set up the backup scheduler: ${GREEN}sudo -u postgres crontab -e${NC} (Add schedules in docs/setup-guide.md)"
}

main "$@"
