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
HEALTH_CHECK_RETRIES=10
HEALTH_CHECK_INTERVAL=5
PRUNE_ALL_IMAGES=false
PRUNE_VOLUMES=false
NOTIFY_EMAIL=""
NOTIFY_WEBHOOK=""
NOTIFY_SUMMARY_ONLY=false

# Lock file to prevent concurrent runs
LOCKFILE="/tmp/compose_updater.lock"

# Notification tracking
declare -a UPDATED_CONTAINERS
declare -a FAILED_CONTAINERS
declare -a SKIPPED_CONTAINERS
START_TIME=$(date +%s)

# --- Utility functions ---

log_info() {
    local ts=""
    if [ "${LOG_WITH_TIMESTAMP:-false}" = true ]; then
        ts="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${GREEN}${ts}[INFO]${NC} $1"
}

log_warn() {
    local ts=""
    if [ "${LOG_WITH_TIMESTAMP:-false}" = true ]; then
        ts="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${YELLOW}${ts}[WARN]${NC} $1"
}

log_error() {
    local ts=""
    if [ "${LOG_WITH_TIMESTAMP:-false}" = true ]; then
        ts="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${RED}${ts}[ERROR]${NC} $1" >&2
}

log_dry_run() {
    local ts=""
    if [ "${LOG_WITH_TIMESTAMP:-false}" = true ]; then
        ts="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${BLUE}${ts}[DRY-RUN]${NC} $1"
}

log_success() {
    local ts=""
    if [ "${LOG_WITH_TIMESTAMP:-false}" = true ]; then
        ts="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${GREEN}${ts}[SUCCESS]${NC} $1"
}

log_debug() {
    local ts=""
    if [ "${LOG_WITH_TIMESTAMP:-false}" = true ]; then
        ts="$(date '+%Y-%m-%d %H:%M:%S') "
    fi
    echo -e "${PURPLE}${ts}[DEBUG]${NC} $1"
}

# Validate that a value is a positive integer
validate_positive_integer() {
    local label="$1"
    local value="$2"
    
    if [[ ! "$value" =~ ^[0-9]+$ ]] || [ "$value" -le 0 ]; then
        log_error "$label must be a positive integer (got: '$value')"
        exit 1
    fi
}

# Safely expand arrays under set -u
# Usage: array_length array_name [default=0]
array_length() {
    local name="$1"
    local default="${2:-0}"
    eval "echo \"\${#$name[@]:-$default}\""
}

# --- Helper: image tracking and cleanup ---

# Return the image names referenced by a compose file, one per line
get_compose_image_names() {
    local container="$1"
    local compose_file="$2"
    local names

    names=$(lxc-attach -n "$container" -- sh -c \
        "cd $COMPOSE_PATH && docker compose -f $compose_file config --images 2>/dev/null" || true)

    if [ -z "$names" ]; then
        # Older Compose versions lack 'config --images'; parse the rendered config instead
        names=$(lxc-attach -n "$container" -- sh -c \
            "cd $COMPOSE_PATH && docker compose -f $compose_file config 2>/dev/null" || true)
        names=$(printf '%s\n' "$names" | sed -n 's/^[[:space:]]*image:[[:space:]]*//p' | tr -d '"' | sort -u)
    fi

    printf '%s\n' "$names"
}

# Return the local image IDs for the images referenced by a compose file, one per line
get_compose_image_ids() {
    local container="$1"
    local compose_file="$2"
    local image

    get_compose_image_names "$container" "$compose_file" | while IFS= read -r image; do
        [ -z "$image" ] && continue
        lxc-attach -n "$container" -- docker image inspect --format '{{.Id}}' "$image" 2>/dev/null || true
    done | sort -u
}

# Return the image IDs actually used by the compose project's containers, one per line.
# Falls back to the images referenced by the compose file when no containers exist.
get_active_image_ids() {
    local container="$1"
    local compose_file="$2"
    local ids

    ids=$(lxc-attach -n "$container" -- sh -c \
        "cd $COMPOSE_PATH && docker compose -f $compose_file ps -q 2>/dev/null |
         while IFS= read -r cid; do
             [ -n \"\$cid\" ] && docker inspect --format '{{.Image}}' \"\$cid\" 2>/dev/null
         done" | sort -u || true)

    if [ -z "$ids" ]; then
        ids=$(get_compose_image_ids "$container" "$compose_file")
    fi

    printf '%s\n' "$ids"
}

# Remove images that were used before the update and are no longer referenced by the compose file
cleanup_replaced_images() {
    local container="$1"
    local old_ids="$2"
    local new_ids="$3"
    local id

    while IFS= read -r id; do
        [ -z "$id" ] && continue

        if printf '%s\n' "$new_ids" | grep -qxF "$id"; then
            continue
        fi

        log_info "Container $container: Removing replaced image $id"
        if ! lxc-attach -n "$container" -- docker image rm "$id" >/dev/null 2>&1; then
            log_debug "Container $container: Image $id is still in use, keeping it"
        fi
    done <<< "$old_ids"
}

# Prune unused Docker resources inside a container
prune_docker_resources() {
    local container="$1"
    local -a image_prune_args=(-f)

    if [ "$PRUNE_ALL_IMAGES" = true ]; then
        image_prune_args=(-a -f)
    fi

    log_info "Container $container: Pruning unused images..."
    if ! lxc-attach -n "$container" -- docker image prune "${image_prune_args[@]}" 2>/dev/null; then
        log_warn "Container $container: Failed to prune unused images"
    fi

    log_info "Container $container: Pruning stopped containers, unused networks and build cache..."
    if ! lxc-attach -n "$container" -- docker system prune -f 2>/dev/null; then
        log_warn "Container $container: Failed to prune Docker resources"
    fi

    if [ "$PRUNE_VOLUMES" = true ]; then
        log_info "Container $container: Pruning unused volumes..."
        if ! lxc-attach -n "$container" -- docker volume prune -f 2>/dev/null; then
            log_warn "Container $container: Failed to prune unused volumes"
        fi
    fi
}

# Log Docker's disk usage so reclaimed space is visible in the run log
log_docker_disk_usage() {
    local container="$1"
    local label="$2"
    local usage

    usage=$(lxc-attach -n "$container" -- docker system df 2>/dev/null || true)
    if [ -n "$usage" ]; then
        log_info "Container $container: Docker disk usage ($label):"
        printf '%s\n' "$usage" | sed 's/^/  /'
    fi
}

# --- Helper: lock file to prevent concurrent runs ---

acquire_lock() {
    if [ -f "$LOCKFILE" ]; then
        local existing_pid
        existing_pid=$(cat "$LOCKFILE" 2>/dev/null || echo "unknown")
        log_error "Another instance is already running (PID: $existing_pid). Remove $LOCKFILE if this is stale."
        exit 1
    fi
    echo $$ > "$LOCKFILE"
    trap 'rm -f "$LOCKFILE"' EXIT
}

# --- Parse command line arguments ---

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
    echo "  --health-check-retries N   Number of health check retries (default: 10)"
    echo "  --health-check-interval SEC  Seconds to wait between health check retries (default: 5)"
    echo "  --prune-all-images       Remove all unused images, including tagged ones"
    echo "  --prune-volumes          Remove unused volumes (destructive, opt-in only)"
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
            validate_positive_integer "Health check timeout" "$2"
            HEALTH_CHECK_TIMEOUT="$2"
            shift 2
            ;;
        --health-check-retries)
            validate_positive_integer "Health check retries" "$2"
            HEALTH_CHECK_RETRIES="$2"
            shift 2
            ;;
        --health-check-interval)
            validate_positive_integer "Health check interval" "$2"
            HEALTH_CHECK_INTERVAL="$2"
            shift 2
            ;;
        --prune-all-images)
            PRUNE_ALL_IMAGES=true
            shift
            ;;
        --prune-volumes)
            PRUNE_VOLUMES=true
            shift
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
            log_error "Unknown option: $1"
            echo "Usage: $0 [--dry-run] [--compose-path PATH] [--compose-files FILE1,FILE2,...] [--filter PATTERN] [--prune-all-images] [--prune-volumes] [--help]"
            exit 1
            ;;
    esac
done

# Validate hook paths before proceeding (only for live runs, not dry-run)
if [ "$DRY_RUN" = false ]; then
    if [ -n "$PRE_UPDATE_HOOK" ]; then
        if [ ! -f "$PRE_UPDATE_HOOK" ]; then
            log_error "Pre-update hook file not found: $PRE_UPDATE_HOOK"
            exit 1
        fi
        if [ ! -x "$PRE_UPDATE_HOOK" ]; then
            log_error "Pre-update hook is not executable: $PRE_UPDATE_HOOK"
            exit 1
        fi
    fi
    if [ -n "$POST_UPDATE_HOOK" ]; then
        if [ ! -f "$POST_UPDATE_HOOK" ]; then
            log_error "Post-update hook file not found: $POST_UPDATE_HOOK"
            exit 1
        fi
        if [ ! -x "$POST_UPDATE_HOOK" ]; then
            log_error "Post-update hook is not executable: $POST_UPDATE_HOOK"
            exit 1
        fi
    fi
fi

# --- Health check function ---

check_container_health() {
    local container="$1"
    local compose_file="$2"
    local timeout="$3"
    local retries="$4"
    local interval="$5"

    log_info "Container $container: Starting health check (timeout: ${timeout}s, retries: $retries, interval: ${interval}s)..."

    local attempt=1
    local healthy=false

    while [ $attempt -le $retries ]; do
        log_info "Container $container: Health check attempt $attempt/$retries..."

        local ps_output
        ps_output=$(lxc-attach -n "$container" -- sh -c "cd $COMPOSE_PATH && timeout $timeout docker compose -f $compose_file ps --format json" 2>/dev/null || true)

        # Compose v1 and v2 use different JSON fields for the running state
        if printf '%s\n' "$ps_output" | grep -qE '"State"[[:space:]]*:[[:space:]]*"running"|"Running"[[:space:]]*:[[:space:]]*true|"Status"[[:space:]]*:[[:space:]]*"Up'; then
            log_info "Container $container: Services are running"

            # An empty "Health" field means no health check is defined for that service
            local health_statuses
            health_statuses=$(printf '%s\n' "$ps_output" \
                | grep -oE '"Health"[[:space:]]*:[[:space:]]*"[^"]*"' \
                | sed 's/.*:[[:space:]]*"\(.*\)"/\1/' \
                | grep -v '^$' || true)

            if [ -z "$health_statuses" ]; then
                log_info "Container $container: No health check defined, but services are running"
                healthy=true
                break
            elif printf '%s\n' "$health_statuses" | grep -qx 'unhealthy'; then
                log_warn "Container $container: Health check reports status: unhealthy"
            elif printf '%s\n' "$health_statuses" | grep -qx 'starting'; then
                log_warn "Container $container: Health check reports status: starting"
            else
                log_success "Container $container: Health check passed (status: healthy)"
                healthy=true
                break
            fi
        else
            log_warn "Container $container: Services not running yet..."
        fi

        if [ $attempt -lt $retries ]; then
            log_info "Container $container: Waiting ${interval}s before next attempt..."
            sleep "$interval"
        fi

        attempt=$((attempt + 1))
    done

    if [ "$healthy" = false ]; then
        log_error "Container $container: Health check failed after $retries attempts"
        return 1
    fi

    return 0
}

# --- Notification functions ---

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

# Safely build JSON by escaping special characters in a string
# Produces JSON-safe string: escapes backslashes, quotes, and newlines
json_escape() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$//' | tr '\n' ' '
}

send_webhook_notification() {
    local message="$1"
    
    if [ -z "$NOTIFY_WEBHOOK" ]; then
        return 0
    fi
    
    log_info "Sending webhook notification to: $NOTIFY_WEBHOOK"
    
    # Use curl if available, otherwise log that webhook would be sent
    if command -v curl >/dev/null 2>&1; then
        # Build JSON payload using jq if available for safe encoding, otherwise escape manually
        local json_payload
        if command -v jq >/dev/null 2>&1; then
            json_payload=$(jq -n \
                --arg msg "$message" \
                --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
                '{"message": $msg, "timestamp": $ts}')
        else
            local escaped_msg escaped_ts
            escaped_msg=$(json_escape "$message")
            escaped_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
            json_payload="{\"message\": \"$escaped_msg\", \"timestamp\": \"$escaped_ts\"}"
        fi
        
        curl -sf -X POST -H "Content-Type: application/json" -d "$json_payload" "$NOTIFY_WEBHOOK" 2>/dev/null || {
            log_warn "Failed to send webhook notification"
            log_debug "Webhook payload: $json_payload"
            return 1
        }
    else
        log_warn "curl command not available, webhook notification would be sent to: $NOTIFY_WEBHOOK"
        local escaped_msg
        escaped_msg=$(json_escape "$message")
        log_info "Webhook Payload: {\"message\": \"$escaped_msg\", \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
    fi
    
    return 0
}

send_notification() {
    local subject="$1"
    local message="$2"
    
    send_email_notification "$subject" "$message"
    send_webhook_notification "$message"
}

# --- Final notification (wrapped in function to avoid 'local' outside functions) ---

send_final_notification() {
    local subject="Compose Updater: Update Process Completed"
    local message="Compose Updater Update Summary\n\n"
    message+="Start Time: $(date -d @$START_TIME '+%Y-%m-%d %H:%M:%S')\n"
    message+="End Time: $(date -d @$(date +%s) '+%Y-%m-%d %H:%M:%S')\n"
    local duration
    duration=$(( $(date +%s) - START_TIME ))
    message+="Duration: ${duration} seconds\n\n"
    
    message+="Updated Containers: $(array_length UPDATED_CONTAINERS)\n"
    if [ "$(array_length UPDATED_CONTAINERS)" -gt 0 ]; then
        local uc
        for uc in "${UPDATED_CONTAINERS[@]}"; do
            message+="  - $uc\n"
        done
    fi
    message+="\n"
    
    message+="Failed Containers: $(array_length FAILED_CONTAINERS)\n"
    if [ "$(array_length FAILED_CONTAINERS)" -gt 0 ]; then
        local fc
        for fc in "${FAILED_CONTAINERS[@]}"; do
            message+="  - $fc\n"
        done
    fi
    message+="\n"
    
    message+="Skipped Containers: $(array_length SKIPPED_CONTAINERS)\n"
    if [ "$(array_length SKIPPED_CONTAINERS)" -gt 0 ]; then
        local sc
        for sc in "${SKIPPED_CONTAINERS[@]}"; do
            message+="  - $sc\n"
        done
    fi
    
    if [ "$(array_length FAILED_CONTAINERS)" -gt 0 ]; then
        subject="Compose Updater: Update Process Completed with Failures"
        message+="\n\n⚠️  WARNING: Some containers failed during update process"
    else
        message+="\n\n✅ All containers processed successfully"
    fi
    
    send_notification "$subject" "$message"
}

# --- Main execution ---

if [ "$DRY_RUN" = true ]; then
    log_dry_run "Running in DRY-RUN mode - no changes will be made"
    echo ""
fi

# Acquire lock to prevent concurrent runs
if [ "$DRY_RUN" = false ]; then
    acquire_lock
fi

# Get list of running LXC containers — do NOT suppress stderr; report errors
log_info "Finding running LXC containers..."
if ! running_containers=$(lxc-ls --running 2>&1); then
    log_error "Failed to get list of running LXC containers. Is lxc-ls installed and are you running on a Proxmox host?"
    log_error "Error output: $running_containers"
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
        if ! "$PRE_UPDATE_HOOK" "$container"; then
            log_warn "Container $container: Pre-update hook returned non-zero exit code (output above)"
        fi
    elif [ -n "$PRE_UPDATE_HOOK" ] && [ "$DRY_RUN" = true ]; then
        log_dry_run "Container $container: Would run pre-update hook: $PRE_UPDATE_HOOK $container"
    fi

    # Pull latest images and capture output
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Container $container: Would record image IDs currently used by the compose project"
        log_dry_run "Container $container: Would run: docker compose -f $found_compose_file pull"
        log_dry_run "Container $container: Would compare image IDs before and after the pull to detect updates"
        log_dry_run "Container $container: If new images detected, would run: docker compose -f $found_compose_file down"
        log_dry_run "Container $container: If new images detected, would run: docker compose -f $found_compose_file up -d"
        log_dry_run "Container $container: If new images detected, would remove replaced images"
        if [ "$PRUNE_ALL_IMAGES" = true ]; then
            log_dry_run "Container $container: Would run: docker image prune -a -f"
        else
            log_dry_run "Container $container: Would run: docker image prune -f"
        fi
        log_dry_run "Container $container: Would run: docker system prune -f"
        if [ "$PRUNE_VOLUMES" = true ]; then
            log_dry_run "Container $container: Would run: docker volume prune -f"
        fi
    else
        old_image_ids=$(get_active_image_ids "$container" "$found_compose_file")
        log_docker_disk_usage "$container" "before update"

        log_info "Container $container: Pulling latest images..."
        if ! pull_output=$(lxc-attach -n "$container" -- sh -c "cd $COMPOSE_PATH && docker compose -f $found_compose_file pull" 2>&1); then
            log_error "Container $container: Failed to pull images"
            echo "$pull_output" | sed 's/^/  /' >&2
            continue
        fi

        echo "$pull_output" | sed 's/^/  /'

        # Compare the image IDs used by the running project with the IDs the
        # compose file now resolves to. This is independent of Compose output
        # formatting and also recovers from earlier runs that pulled a new
        # image but never restarted the services.
        new_image_ids=$(get_compose_image_ids "$container" "$found_compose_file")

        images_changed=false
        if [ "$old_image_ids" != "$new_image_ids" ]; then
            images_changed=true
        elif echo "$pull_output" | grep -qE '^\s*(Status:\s*(Downloaded newer image|Downloading|Download complete))'; then
            # Fallback for when image IDs could not be resolved
            images_changed=true
        fi

        if [ "$images_changed" = true ]; then
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

            log_success "Container $container: Update complete"

            # Run health check if enabled
            if [ "$HEALTH_CHECK" = true ] && [ "$DRY_RUN" = false ]; then
                if check_container_health "$container" "$found_compose_file" "$HEALTH_CHECK_TIMEOUT" "$HEALTH_CHECK_RETRIES" "$HEALTH_CHECK_INTERVAL"; then
                    log_success "Container $container: Health check completed successfully"
                    UPDATED_CONTAINERS+=("$container")
                else
                    log_error "Container $container: Health check failed"
                    FAILED_CONTAINERS+=("$container")
                    # Keep the previous images available for rollback
                    continue
                fi
            elif [ "$HEALTH_CHECK" = true ] && [ "$DRY_RUN" = true ]; then
                log_dry_run "Container $container: Would perform health check (timeout: ${HEALTH_CHECK_TIMEOUT}s, retries: $HEALTH_CHECK_RETRIES, interval: ${HEALTH_CHECK_INTERVAL}s)"
            fi

            # Clean up images replaced by this update. Only remove images that
            # are no longer used by any container; 'docker image rm' refuses
            # otherwise, so other compose projects are never affected.
            log_info "Container $container: Cleaning up replaced images..."
            current_image_ids=$(get_active_image_ids "$container" "$found_compose_file")
            cleanup_replaced_images "$container" "$old_image_ids" "$current_image_ids"

            prune_docker_resources "$container"
            log_docker_disk_usage "$container" "after update"

            # Run post-update hook if specified
            if [ -n "$POST_UPDATE_HOOK" ] && [ "$DRY_RUN" = false ]; then
                log_info "Container $container: Running post-update hook: $POST_UPDATE_HOOK"
                if ! "$POST_UPDATE_HOOK" "$container"; then
                    log_warn "Container $container: Post-update hook returned non-zero exit code (output above)"
                fi
            elif [ -n "$POST_UPDATE_HOOK" ] && [ "$DRY_RUN" = true ]; then
                log_dry_run "Container $container: Would run post-update hook: $POST_UPDATE_HOOK $container"
            fi
        else
            log_info "Container $container: No new images available, skipping update"

            # Sweep dangling images left behind by earlier runs even when no
            # update is detected. Tagged images are left alone here.
            log_info "Container $container: Pruning dangling images..."
            if ! lxc-attach -n "$container" -- docker image prune -f 2>/dev/null; then
                log_warn "Container $container: Failed to prune dangling images"
            fi
        fi
    fi

    echo ""
done

log_info "All containers processed"

# Send final notification if configured
if [ "$DRY_RUN" = false ] && ([ -n "$NOTIFY_EMAIL" ] || [ -n "$NOTIFY_WEBHOOK" ]); then
    send_final_notification
fi
