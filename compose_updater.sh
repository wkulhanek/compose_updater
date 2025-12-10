#!/bin/bash

# compose_updater.sh
# Updates Docker Compose applications across running LXC containers on Proxmox

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Logging with timestamps
LOG_WITH_TIMESTAMP=false

# Default values
DRY_RUN=false
COMPOSE_FILES=("docker-compose.yml" "compose.yaml" "docker-compose.yaml")
COMPOSE_PATH="/root"
CONTAINER_FILTER=""
PRE_UPDATE_HOOK=""
POST_UPDATE_HOOK=""
HEALTH_CHECK=true
HEALTH_CHECK_TIMEOUT=30
HEALTH_CHECK_RETRIES=3
NOTIFY_EMAIL=""
NOTIFY_WEBHOOK=""
NOTIFY_SUMMARY_ONLY=false

# Notification tracking
declare -a UPDATED_CONTAINERS
declare -a FAILED_CONTAINERS
declare -a SKIPPED_CONTAINERS
START_TIME=$(date +%s)

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --dry-run                Run in simulation mode without making changes"
    echo "  --compose-path PATH      Set the path to look for compose files (default: /root)"
    echo "  --compose-files FILES    Comma-separated list of compose file names to check"
    echo "                          (default: docker-compose.yml,compose.yaml,docker-compose.yaml)"
    echo "  --filter PATTERN         Only process containers matching this regex pattern"
    echo "  --timestamp              Add timestamps to log messages"
    echo "  --pre-hook SCRIPT        Run script before updates (passes container name as arg)"
    echo "  --post-hook SCRIPT       Run script after successful updates (passes container name as arg)"
    echo "  --no-health-check        Disable health checks after updates"
    echo "  --health-check-timeout SEC  Health check timeout in seconds (default: 30)"
    echo "  --health-check-retries N   Number of health check retries (default: 3)"
    echo "  --notify-email ADDR       Send email notification to specified address"
    echo "  --notify-webhook URL      Send webhook notification to specified URL"
    echo "  --notify-summary-only     Only send summary notification (not per-container)"
    echo "  --help                   Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --dry-run"
    echo "  $0 --compose-path /opt/myapp --compose-files docker-compose.prod.yml"
    echo "  $0 --filter 'web|api'"
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --compose-path)
            COMPOSE_PATH="$2"
            shift 2
            ;;
        --compose-files)
            IFS=',' read -ra COMPOSE_FILES <<< "$2"
            shift 2
            ;;
        --filter)
            CONTAINER_FILTER="$2"
            shift 2
            ;;
        --timestamp)
            LOG_WITH_TIMESTAMP=true
            shift
            ;;
        --pre-hook)
            PRE_UPDATE_HOOK="$2"
            shift 2
            ;;
        --post-hook)
            POST_UPDATE_HOOK="$2"
            shift 2
            ;;
        --no-health-check)
            HEALTH_CHECK=false
            shift
            ;;
        --health-check-timeout)
            HEALTH_CHECK_TIMEOUT="$2"
            shift 2
            ;;
        --health-check-retries)
            HEALTH_CHECK_RETRIES="$2"
            shift 2
            ;;
        --notify-email)
            NOTIFY_EMAIL="$2"
            shift 2
            ;;
        --notify-webhook)
            NOTIFY_WEBHOOK="$2"
            shift 2
            ;;
        --notify-summary-only)
            NOTIFY_SUMMARY_ONLY=true
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--compose-path PATH] [--compose-files FILE1,FILE2,...] [--filter PATTERN] [--help]"
            exit 1
            ;;
    esac
done

log_info() {
    local timestamp=""
    if [ "$LOG_WITH_TIMESTAMP" = true ]; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${GREEN}${timestamp}[INFO]${NC} $1"
}

log_warn() {
    local timestamp=""
    if [ "$LOG_WITH_TIMESTAMP" = true ]; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${YELLOW}${timestamp}[WARN]${NC} $1"
}

log_error() {
    local timestamp=""
    if [ "$LOG_WITH_TIMESTAMP" = true ]; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${RED}${timestamp}[ERROR]${NC} $1" >&2
}

log_dry_run() {
    local timestamp=""
    if [ "$LOG_WITH_TIMESTAMP" = true ]; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${BLUE}${timestamp}[DRY-RUN]${NC} $1"
}

log_success() {
    local timestamp=""
    if [ "$LOG_WITH_TIMESTAMP" = true ]; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${GREEN}${timestamp}[SUCCESS]${NC} $1"
}

log_debug() {
    local timestamp=""
    if [ "$LOG_WITH_TIMESTAMP" = true ]; then
        timestamp="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${PURPLE}${timestamp}[DEBUG]${NC} $1"
}

# Error handling function
handle_error() {
    local exit_code=$1
    local message="$2"
    local container="$3"
    
    if [ $exit_code -ne 0 ]; then
        log_error "$message"
        if [ -n "$container" ]; then
            log_error "Failed while processing container: $container"
        fi
        log_error "Script failed with exit code: $exit_code"
        exit $exit_code
    fi
}

# Health check function
check_container_health() {
    local container="$1"
    local compose_file="$2"
    local timeout="$3"
    local retries="$4"
    
    log_info "Container $container: Starting health check (timeout: ${timeout}s, retries: $retries)..."
    
    local attempt=1
    local healthy=false
    
    while [ $attempt -le $retries ]; do
        log_info "Container $container: Health check attempt $attempt/$retries..."
        
        # Check if containers are running using docker compose ps
        if lxc-attach -n "$container" -- sh -c "cd $COMPOSE_PATH && docker compose -f $compose_file ps --format json" 2>/dev/null | grep -q '"Running"'; then
            log_info "Container $container: Services are running"
            
            # Check for healthy status if health checks are defined
            local health_status=$(lxc-attach -n "$container" -- sh -c "cd $COMPOSE_PATH && timeout $timeout docker compose -f $compose_file ps --format json" 2>/dev/null | grep -o '"Health"[^,]*')
            
            if [ -z "$health_status" ] || echo "$health_status" | grep -q '"Health"'; then
                # If no health check defined or health check exists, consider healthy
                healthy=true
                log_success "Container $container: Health check passed"
                break
            else
                log_warn "Container $container: Health check not defined, but services are running"
                healthy=true
                break
            fi
        else
            log_warn "Container $container: Services not running, waiting..."
            if [ $attempt -lt $retries ]; then
                sleep 5
            fi
        fi
        
        attempt=$((attempt + 1))
    done
    
    if [ "$healthy" = false ]; then
        log_error "Container $container: Health check failed after $retries attempts"
        return 1
    fi
    
    return 0
}

# Notification functions
send_email_notification() {
    local subject="$1"
    local message="$2"
    
    if [ -z "$NOTIFY_EMAIL" ]; then
        return 0
    fi
    
    log_info "Sending email notification to: $NOTIFY_EMAIL"
    
    # Use mail command if available, otherwise log that email would be sent
    if command -v mail >/dev/null 2>&1; then
        echo "$message" | mail -s "$subject" "$NOTIFY_EMAIL" 2>/dev/null || {
            log_warn "Failed to send email notification"
            return 1
        }
    else
        log_warn "mail command not available, email notification would be sent to: $NOTIFY_EMAIL"
        log_info "Email Subject: $subject"
        log_info "Email Body: $message"
    fi
    
    return 0
}

send_webhook_notification() {
    local message="$1"
    
    if [ -z "$NOTIFY_WEBHOOK" ]; then
        return 0
    fi
    
    log_info "Sending webhook notification to: $NOTIFY_WEBHOOK"
    
    # Use curl if available, otherwise log that webhook would be sent
    if command -v curl >/dev/null 2>&1; then
        curl -X POST -H "Content-Type: application/json" -d "{\"message\": \"$message\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}" "$NOTIFY_WEBHOOK" 2>/dev/null || {
            log_warn "Failed to send webhook notification"
            return 1
        }
    else
        log_warn "curl command not available, webhook notification would be sent to: $NOTIFY_WEBHOOK"
        log_info "Webhook Payload: {\"message\": \"$message\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    fi
    
    return 0
}

send_notification() {
    local subject="$1"
    local message="$2"
    
    send_email_notification "$subject" "$message"
    send_webhook_notification "$message"
}

if [ "$DRY_RUN" = true ]; then
    log_dry_run "Running in DRY-RUN mode - no changes will be made"
    echo ""
fi

# Get list of running LXC containers
log_info "Finding running LXC containers..."
if ! running_containers=$(lxc-ls --running 2>/dev/null); then
    log_error "Failed to get list of running LXC containers. Is lxc-ls installed and are you running on a Proxmox host?"
    exit 1
fi

if [ -z "$running_containers" ]; then
    log_warn "No running LXC containers found"
    exit 0
fi

log_info "Found running containers: $running_containers"

# Process each container
for container in $running_containers; do
    # Apply container filter if specified
    if [ -n "$CONTAINER_FILTER" ]; then
        if ! [[ "$container" =~ $CONTAINER_FILTER ]]; then
            log_info "Container $container: Skipped by filter pattern '$CONTAINER_FILTER'"
            continue
        fi
    fi

    log_info "Processing container: $container"

    # Check for any of the specified compose files
    found_compose_file=""
    for compose_file in "${COMPOSE_FILES[@]}"; do
        full_path="$COMPOSE_PATH/$compose_file"
        if lxc-attach -n "$container" -- test -f "$full_path" 2>/dev/null; then
            found_compose_file="$compose_file"
            break
        fi
    done

    if [ -z "$found_compose_file" ]; then
        log_warn "Container $container: No compose files found in $COMPOSE_PATH (checked: ${COMPOSE_FILES[*]}), skipping"
        SKIPPED_CONTAINERS+=("$container")
        continue
    fi

    log_info "Container $container: Found $found_compose_file in $COMPOSE_PATH"

    # Run pre-update hook if specified
    if [ -n "$PRE_UPDATE_HOOK" ] && [ "$DRY_RUN" = false ]; then
        log_info "Container $container: Running pre-update hook: $PRE_UPDATE_HOOK"
        if ! "$PRE_UPDATE_HOOK" "$container" 2>/dev/null; then
            log_warn "Container $container: Pre-update hook failed or returned non-zero"
        fi
    elif [ -n "$PRE_UPDATE_HOOK" ] && [ "$DRY_RUN" = true ]; then
        log_dry_run "Container $container: Would run pre-update hook: $PRE_UPDATE_HOOK $container"
    fi

    # Pull latest images and capture output
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Container $container: Would run: docker compose -f $found_compose_file pull"
        log_dry_run "Container $container: Simulating image check..."
        # In dry-run mode, simulate that new images might be available
        log_dry_run "Container $container: Would check if new images were pulled"
        log_dry_run "Container $container: If new images found, would run: docker compose -f $found_compose_file down"
        log_dry_run "Container $container: If new images found, would run: docker compose -f $found_compose_file up -d"
        log_dry_run "Container $container: If new images found, would run: docker system prune -f"
    else
        log_info "Container $container: Pulling latest images..."
        if ! pull_output=$(lxc-attach -n "$container" -- sh -c "cd $COMPOSE_PATH && docker compose -f $found_compose_file pull" 2>&1); then
            log_error "Container $container: Failed to pull images"
            echo "$pull_output" | sed 's/^/  /' >&2
            continue
        fi

        echo "$pull_output" | sed 's/^/  /'

        # Check if any new images were pulled
        # Docker Compose outputs "Downloading" when actually fetching new image layers
        # When no updates: only shows "Pulling" and "Pulled" without any download activity
        if echo "$pull_output" | grep -qiE "(Downloading|Downloaded newer image|Download complete)"; then
            log_info "Container $container: New images detected, updating services..."

            # Stop the compose services
            log_info "Container $container: Stopping services..."
            if ! lxc-attach -n "$container" -- sh -c "cd $COMPOSE_PATH && docker compose -f $found_compose_file down" 2>/dev/null; then
                log_error "Container $container: Failed to stop services"
                continue
            fi

            # Start the compose services
            log_info "Container $container: Starting services..."
            if ! lxc-attach -n "$container" -- sh -c "cd $COMPOSE_PATH && docker compose -f $found_compose_file up -d" 2>/dev/null; then
                log_error "Container $container: Failed to start services"
                continue
            fi

            # Clean up unused Docker resources
            log_info "Container $container: Cleaning up unused Docker resources..."
            if ! lxc-attach -n "$container" -- docker system prune -f 2>/dev/null; then
                log_warn "Container $container: Failed to clean up Docker resources"
            fi

            log_success "Container $container: Update complete"
            
            # Run health check if enabled
            if [ "$HEALTH_CHECK" = true ] && [ "$DRY_RUN" = false ]; then
                if check_container_health "$container" "$found_compose_file" "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_RETRIES"; then
                    log_success "Container $container: Health check completed successfully"
                    UPDATED_CONTAINERS+=("$container")
                else
                    log_error "Container $container: Health check failed"
                    FAILED_CONTAINERS+=("$container")
                    continue
                fi
            elif [ "$HEALTH_CHECK" = true ] && [ "$DRY_RUN" = true ]; then
                log_dry_run "Container $container: Would perform health check (timeout: ${HEALTH_CHECK_TIMEOUT}s, retries: $HEALTH_CHECK_RETRIES)"
            fi
            
            # Run post-update hook if specified
            if [ -n "$POST_UPDATE_HOOK" ] && [ "$DRY_RUN" = false ]; then
                log_info "Container $container: Running post-update hook: $POST_UPDATE_HOOK"
                if ! "$POST_UPDATE_HOOK" "$container" 2>/dev/null; then
                    log_warn "Container $container: Post-update hook failed or returned non-zero"
                fi
            elif [ -n "$POST_UPDATE_HOOK" ] && [ "$DRY_RUN" = true ]; then
                log_dry_run "Container $container: Would run post-update hook: $POST_UPDATE_HOOK $container"
            fi
        else
            log_info "Container $container: No new images available, skipping update"
        fi
    fi

    echo ""
done

log_info "All containers processed"

# Send final notification if configured
if [ "$DRY_RUN" = false ] && ([ -n "$NOTIFY_EMAIL" ] || [ -n "$NOTIFY_WEBHOOK" ]); then
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    
    local subject="Compose Updater: Update Process Completed"
    local message="Compose Updater Update Summary\n\n"
    message+="Start Time: $(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S')\n"
    message+="End Time: $(date -d @$END_TIME '+%Y-%m-%d %H:%M:%S')\n"
    message+="Duration: ${DURATION} seconds\n\n"
    
    message+="Updated Containers: ${#UPDATED_CONTAINERS[@]}\n"
    if [ ${#UPDATED_CONTAINERS[@]} -gt 0 ]; then
        for container in "${UPDATED_CONTAINERS[@]}"; do
            message+="  - $container\n"
        done
    fi
    message+="\n"
    
    message+="Failed Containers: ${#FAILED_CONTAINERS[@]}\n"
    if [ ${#FAILED_CONTAINERS[@]} -gt 0 ]; then
        for container in "${FAILED_CONTAINERS[@]}"; do
            message+="  - $container\n"
        done
    fi
    message+="\n"
    
    message+="Skipped Containers: ${#SKIPPED_CONTAINERS[@]}\n"
    if [ ${#SKIPPED_CONTAINERS[@]} -gt 0 ]; then
        for container in "${SKIPPED_CONTAINERS[@]}"; do
            message+="  - $container\n"
        done
    fi
    
    if [ ${#FAILED_CONTAINERS[@]} -gt 0 ]; then
        subject="Compose Updater: Update Process Completed with Failures"
        message+="\n\n⚠️  WARNING: Some containers failed during update process"
    else
        message+="\n\n✅ All containers processed successfully"
    fi
    
    send_notification "$subject" "$message"
fi
