#!/bin/bash
#
# production_monitor.sh - Production System Monitor
# Purpose: Monitor critical services and system resources
# Author: DevOps Team
# Version: 1.0
#

# Safety settings
set -euo pipefail
#IFS=$'\n\t'

# Configuration
readonly SCRIPT_NAME=$(basename "$0")
readonly LOG_DIR="/var/log/monitoring"
readonly LOG_FILE="$LOG_DIR/monitor_$(date +%Y%m%d).log"
readonly ALERT_EMAIL="devops-team@company.com"
readonly SLACK_WEBHOOK="https://hooks.slack.com/services/XXX/YYY/ZZZ"

# Thresholds
readonly DISK_THRESHOLD=85
readonly MEMORY_THRESHOLD=90
readonly CPU_THRESHOLD=80

# Critical services to monitor
readonly CRITICAL_SERVICES=(
    "nginx"
    "mysql"
    "redis"
    "docker"
)

# Initialize
initialize() {
    # Create log directory if it doesn't exist
    [[ ! -d "$LOG_DIR" ]] && mkdir -p "$LOG_DIR"

    # Check if running as root (for service management)
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi

    log_info "=== Starting $SCRIPT_NAME ==="
}

# Logging functions
log_info() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $@"
    echo "$message" | tee -a "$LOG_FILE"
}

log_error() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $@"
    echo "$message" | tee -a "$LOG_FILE"
}

log_warning() {
    local message="[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $@"
    echo "$message" | tee -a "$LOG_FILE"
}

# Alert functions
send_email_alert() {
    local subject=$1
    local body=$2

     echo "$body" | mail -s "$subject" "$ALERT_EMAIL" || log_error "Failed to send email alert"

}

send_slack_alert() {
    local message=$1

    curl -X POST -H 'Content-type: application/json' \
        --data "{\"text\":\"Alert: $message\"}" \
        "$SLACK_WEBHOOK" || log_error "Failed to send Slack alert"
}

# Check critical services
check_services() {
    log_info "Checking critical services..."
    local failed_services=()

    for service in "${CRITICAL_SERVICES[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_info " $service is running"
        else
            log_error " $service is not running"
            failed_services+=("$service")

            # Attempt auto-recovery
            log_info "  Attempting to restart $service..."
            if systemctl restart "$service"; then
                sleep 2
                if systemctl is-active --quiet "$service"; then
                    log_info "  Successfully restarted $service"
                    send_slack_alert "$service was down but has been automatically restarted"
                else
                    log_error "  Failed to restart $service"
                fi
            fi
        fi
    done

    if [[ ${#failed_services[@]} -gt 0 ]]; then
        send_email_alert "Critical Services Down" "The following services are not running: ${failed_services[*]}"
        return 1
    fi

    return 0
}

# Check disk usage
check_disk_usage() {
    log_info "Checking disk usage..."
    local alert_triggered=false

    while IFS= read -r line; do
        local usage=$(echo "$line" | awk '{print $5}' | sed 's/%//')
        local partition=$(echo "$line" | awk '{print $6}')

        if [[ $usage -gt $DISK_THRESHOLD ]]; then
            log_warning "  High disk usage on $partition: ${usage}%"
            send_slack_alert "High disk usage on $partition: ${usage}% (threshold: ${DISK_THRESHOLD}%)"
            alert_triggered=true

            # Auto-cleanup old logs if /var/log is affected
#            if [[ "$partition" == "/var/log" ]] || [[ "$partition" == "/" ]]; then
#                log_info "  Cleaning old logs..."
#                find /var/log -name "*.log" -mtime +30 -delete 2>/dev/null
#                find /tmp -type f -mtime +7 -delete 2>/dev/null
#            fi
        else
            log_info "  $partition: ${usage}% used"
        fi
    done < <(df -h | grep -E '^/dev/' | grep -v '/boot')

    [[ "$alert_triggered" == true ]] && return 1 || return 0
}

# Check memory usage
check_memory_usage() {
    log_info "Checking memory usage..."

    local total_mem=$(free -m | awk 'NR==2{print $2}')
    local used_mem=$(free -m | awk 'NR==2{print $3}')
    local usage_percent=$((used_mem * 100 / total_mem))

    log_info "  Memory usage: ${usage_percent}% (${used_mem}MB/${total_mem}MB)"
    if [[ $usage_percent -gt $MEMORY_THRESHOLD ]]; then
        log_warning "  High memory usage: ${usage_percent}%"

        # Find top memory consumers
        local top_processes=$(ps aux --sort=-%mem | head -6 | tail -5)
        send_slack_alert "High memory usage: ${usage_percent}%\n\nTop processes:\n$top_processes"

        return 1
    fi

    return 0
}

# Check database connectivity
#check_database() {
#    log_info "Checking database connectivity..."
#
#    if mysqladmin ping -h localhost &>/dev/null; then
#        log_info "  ✓ Database is responding"
#
#        # Check for slow queries
#        local slow_queries=$(mysql -e "SHOW STATUS LIKE 'Slow_queries';" | awk 'NR==2{print $2}')
#        if [[ $slow_queries -gt 100 ]]; then
#            log_warning "  High number of slow queries: $slow_queries"
#        fi
#
#        return 0
#    else
#        log_error "  ✗ Database is not responding"
#        send_email_alert "Database Connection Failed" \
#            "Unable to connect to MySQL database on localhost"
#        return 1
#    fi
#}

# Main monitoring function
perform_health_check() {
    local status=0

    check_services || status=1
    check_disk_usage || status=1
    check_memory_usage || status=1
    check_database || status=1

    if [[ $status -eq 0 ]]; then
        log_info "=== All checks passed ✓ ==="
    else
        log_error "=== Some checks failed ✗ ==="
    fi

    return $status
}

# Cleanup on exit
cleanup() {
    log_info "=== Monitoring script ended ==="
}

# Set up signal handlers
trap cleanup EXIT
trap 'log_error "Script interrupted"; exit 130' INT TERM

# Main execution
main() {
    initialize

    case "${1:-}" in
        --once)
            perform_health_check
            ;;
        --continuous)
            log_info "Running in continuous mode (Ctrl+C to stop)"
            while true; do
                perform_health_check || true  # Continue even if checks fail
                log_info "Sleeping for 5 minutes..."
                sleep 300
            done
            ;;
        *)
            echo "Usage: $0 {--once|--continuous}"
            echo "  --once       Run checks once and exit"
            echo "  --continuous Run checks every 5 minutes"
            exit 1
            ;;
    esac
}

# Run the script
main "$@"
