#!/bin/bash

# compose_updater.sh
# Updates Docker Compose applications across running LXC containers on Proxmox

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
DRY_RUN=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--dry-run]"
            exit 1
            ;;
    esac
done

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_dry_run() {
    echo -e "${BLUE}[DRY-RUN]${NC} $1"
}

if [ "$DRY_RUN" = true ]; then
    log_dry_run "Running in DRY-RUN mode - no changes will be made"
    echo ""
fi

# Get list of running LXC containers
log_info "Finding running LXC containers..."
running_containers=$(lxc-ls --running)

if [ -z "$running_containers" ]; then
    log_warn "No running LXC containers found"
    exit 0
fi

log_info "Found running containers: $running_containers"

# Process each container
for container in $running_containers; do
    log_info "Processing container: $container"

    # Check if docker-compose.yml exists in home directory
    if ! lxc-attach -n "$container" -- test -f /root/docker-compose.yml; then
        log_warn "Container $container: No /root/docker-compose.yml found, skipping"
        continue
    fi

    log_info "Container $container: Found docker-compose.yml"

    # Pull latest images and capture output
    if [ "$DRY_RUN" = true ]; then
        log_dry_run "Container $container: Would run: docker compose pull"
        log_dry_run "Container $container: Simulating image check..."
        # In dry-run mode, simulate that new images might be available
        log_dry_run "Container $container: Would check if new images were pulled"
        log_dry_run "Container $container: If new images found, would run: docker compose down"
        log_dry_run "Container $container: If new images found, would run: docker compose up -d"
        log_dry_run "Container $container: If new images found, would run: docker system prune -f"
    else
        log_info "Container $container: Pulling latest images..."
        pull_output=$(lxc-attach -n "$container" -- sh -c 'cd /root && docker compose pull' 2>&1)

        # Check if any new images were pulled
        # Docker Compose outputs "Pulled" or "Downloaded" when new images are fetched
        if echo "$pull_output" | grep -qE "(Pulled|Downloaded newer image)"; then
            log_info "Container $container: New images detected, updating services..."

            # Stop the compose services
            log_info "Container $container: Stopping services..."
            lxc-attach -n "$container" -- sh -c 'cd /root && docker compose down'

            # Start the compose services
            log_info "Container $container: Starting services..."
            lxc-attach -n "$container" -- sh -c 'cd /root && docker compose up -d'

            # Clean up unused Docker resources
            log_info "Container $container: Cleaning up unused Docker resources..."
            lxc-attach -n "$container" -- docker system prune -f

            log_info "Container $container: Update complete"
        else
            log_info "Container $container: No new images available, skipping update"
        fi
    fi

    echo ""
done

log_info "All containers processed"
