#!/bin/bash
# check-agent-health.sh
# Monitoring cron script - runs every 15 minutes
# Parses agent timestamps and alerts on stale agents
#
# Usage: ./check-agent-health.sh [--dry-run]
#
# Cron entry: */15 * * * * ~/path/to/check-agent-health.sh

set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DASHBOARD_PATH="${SCRIPT_DIR}/agent-health.md"
INCIDENT_LOG_PATH="${SCRIPT_DIR}/agent-health-incidents.md"
LOCK_DIR="/tmp/agent-health-dashboard.lock"
LOCK_TIMEOUT=10
ALERT_FILE="/tmp/agent-health-last-alert"
DEBOUNCE_SECONDS=1800  # 30 minutes
STATE_DIR="/tmp/agent-health-state"

# Temp files for agent data (avoids associative arrays for bash 3 compatibility)
TEMP_DIR="/tmp/agent-health-data"
mkdir -p "$TEMP_DIR"
mkdir -p "$STATE_DIR"

# Dry run mode (don't send alerts)
DRY_RUN=0
if [ "$1" = "--dry-run" ]; then
    DRY_RUN=1
fi

# Current time
CURRENT_EPOCH=$(date +%s)

# List of known agents
KNOWN_AGENTS="Duncan Leto Stilgar"

# Function to parse timestamp to epoch
# Handles format: "2026-02-13T09:30:00 EST"
parse_timestamp() {
    local ts="$1"

    # Remove timezone suffix for parsing
    local ts_clean=$(echo "$ts" | sed 's/ [A-Z]*$//')

    # macOS compatible: date -j -f format
    local result=$(date -j -f "%Y-%m-%dT%H:%M:%S" "$ts_clean" +%s 2>/dev/null || echo "0")
    echo "$result"
}

# Function to format minutes as human readable
format_staleness() {
    local minutes="$1"
    if [ "$minutes" -ge 60 ]; then
        local hours=$((minutes / 60))
        local mins=$((minutes % 60))
        echo "${hours}h ${mins}m"
    else
        echo "${minutes}m"
    fi
}

# Function to get previous state for an agent
get_previous_state() {
    local agent="$1"
    local state_file="${STATE_DIR}/${agent}.state"
    if [ -f "$state_file" ]; then
        cat "$state_file"
    else
        echo "unknown"
    fi
}

# Function to save current state for an agent
save_state() {
    local agent="$1"
    local state="$2"
    echo "$state" > "${STATE_DIR}/${agent}.state"
}

# Function to log incident to agent-health-incidents.md
log_incident() {
    local agent="$1"
    local incident_type="$2"  # warning, critical, or recovered
    local stale_time="$3"
    local model="$4"
    local channel="$5"

    local timestamp
    timestamp=$(date '+%Y-%m-%dT%H:%M:%S %Z')

    # Determine emoji based on type
    local emoji
    case "$incident_type" in
        warning)  emoji="🟡" ;;
        critical) emoji="🔴" ;;
        recovered) emoji="🟢" ;;
        *)        emoji="⚪" ;;
    esac

    # Append to incident log
    {
        echo ""
        echo "## ${timestamp}"
        if [ "$incident_type" = "recovered" ]; then
            echo "- ${emoji} ${agent}: Recovered"
        else
            local stale_human
            stale_human=$(format_staleness "$stale_time")
            # Capitalize first letter for display (bash 3 compatible)
            local type_display
            case "$incident_type" in
                warning)  type_display="Warning" ;;
                critical) type_display="Critical" ;;
                *)        type_display="$incident_type" ;;
            esac
            echo "- ${emoji} ${agent}: ${type_display} (${stale_human} stale)"
            echo "- Model: ${model}"
            echo "- Channel: ${channel}"
        fi
    } >> "$INCIDENT_LOG_PATH"

    echo "Logged incident: ${emoji} ${agent} ${incident_type}"
}

# Function to extract agent metadata from dashboard section
extract_agent_metadata() {
    local section="$1"
    local field="$2"
    echo "$section" | grep "\*\*${field}:\*\*" | sed "s/.*\*\*${field}:\*\* //" | xargs
}

# Function to acquire lock (mkdir is atomic on all Unix systems)
acquire_lock() {
    local waited=0
    while [ $waited -lt $LOCK_TIMEOUT ]; do
        if mkdir "$LOCK_DIR" 2>/dev/null; then
            echo $$ > "$LOCK_DIR/pid"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

# Function to release lock
release_lock() {
    rm -rf "$LOCK_DIR" 2>/dev/null || true
}

# Function to send alert via openclaw gateway
send_alert() {
    local message="$1"

    if [ "$DRY_RUN" -eq 1 ]; then
        echo "[DRY RUN] Would send alert:"
        echo "$message"
        return 0
    fi

    # Try openclaw gateway wake first
    if command -v openclaw &> /dev/null; then
        openclaw gateway wake --text "$message" --mode now 2>&1 || {
            echo "Warning: openclaw gateway wake failed" >&2
            return 1
        }
        return 0
    else
        echo "Warning: openclaw not available, cannot send alert" >&2
        echo "$message"
        return 1
    fi
}

# Check if dashboard exists
if [ ! -f "$DASHBOARD_PATH" ]; then
    echo "Error: Dashboard file not found at $DASHBOARD_PATH" >&2
    exit 1
fi

# Read dashboard content
DASHBOARD_CONTENT=$(cat "$DASHBOARD_PATH")

# Clear temp files
for AGENT in $KNOWN_AGENTS; do
    echo "0" > "${TEMP_DIR}/${AGENT}-epoch"
    echo "unknown" > "${TEMP_DIR}/${AGENT}-stale"
done

# Alert tracking
ALERT_MESSAGES=""
CRITICAL_AGENTS=""

# Parse each agent's section
for AGENT in $KNOWN_AGENTS; do
    # Extract Last Ping timestamp for this agent
    # Use awk to extract the section (from header until blank line)
    AGENT_SECTION=$(echo "$DASHBOARD_CONTENT" | awk "/^## ${AGENT} \(/{found=1} found && /^$/{exit} found{print}")

    if [ -z "$AGENT_SECTION" ]; then
        echo "0" > "${TEMP_DIR}/${AGENT}-epoch"
        echo "unknown" > "${TEMP_DIR}/${AGENT}-stale"
        if [ -n "$ALERT_MESSAGES" ]; then
            ALERT_MESSAGES="${ALERT_MESSAGES}
"
        fi
        ALERT_MESSAGES="${ALERT_MESSAGES}⚪ ${AGENT}: Unknown (no section in dashboard)"
        continue
    fi

    # Extract timestamp
    LAST_PING=$(echo "$AGENT_SECTION" | grep "\*\*Last Ping:\*\*" | sed 's/.*\*\*Last Ping:\*\* //' | xargs)

    if [ -z "$LAST_PING" ] || [ "$LAST_PING" = "_No data_" ]; then
        echo "0" > "${TEMP_DIR}/${AGENT}-epoch"
        echo "unknown" > "${TEMP_DIR}/${AGENT}-stale"
        if [ -n "$ALERT_MESSAGES" ]; then
            ALERT_MESSAGES="${ALERT_MESSAGES}
"
        fi
        ALERT_MESSAGES="${ALERT_MESSAGES}⚪ ${AGENT}: Unknown (no data)"
        continue
    fi

    # Parse timestamp to epoch
    PING_EPOCH=$(parse_timestamp "$LAST_PING")

    if [ "$PING_EPOCH" = "0" ]; then
        echo "0" > "${TEMP_DIR}/${AGENT}-epoch"
        echo "unknown" > "${TEMP_DIR}/${AGENT}-stale"
        if [ -n "$ALERT_MESSAGES" ]; then
            ALERT_MESSAGES="${ALERT_MESSAGES}
"
        fi
        ALERT_MESSAGES="${ALERT_MESSAGES}⚪ ${AGENT}: Unknown (invalid timestamp)"
        continue
    fi

    echo "$PING_EPOCH" > "${TEMP_DIR}/${AGENT}-epoch"

    # Calculate staleness
    STALE_SECONDS=$((CURRENT_EPOCH - PING_EPOCH))
    STALE_MINUTES=$((STALE_SECONDS / 60))
    echo "$STALE_MINUTES" > "${TEMP_DIR}/${AGENT}-stale"

    # Determine current status and get previous state for incident logging
    PREV_STATE=$(get_previous_state "$AGENT")
    CURRENT_STATE="healthy"

    # Extract metadata for incident logging
    AGENT_MODEL=$(extract_agent_metadata "$AGENT_SECTION" "Model")
    AGENT_CHANNEL=$(extract_agent_metadata "$AGENT_SECTION" "Channel")

    # Determine status
    if [ "$STALE_MINUTES" -gt 60 ]; then
        CURRENT_STATE="critical"
        STALENESS_HUMAN=$(format_staleness "$STALE_MINUTES")
        if [ -n "$ALERT_MESSAGES" ]; then
            ALERT_MESSAGES="${ALERT_MESSAGES}
"
        fi
        ALERT_MESSAGES="${ALERT_MESSAGES}🔴 ${AGENT}: Critical (${STALENESS_HUMAN} since last ping)"
        CRITICAL_AGENTS="${CRITICAL_AGENTS} ${AGENT}"
    elif [ "$STALE_MINUTES" -gt 30 ]; then
        CURRENT_STATE="warning"
        STALENESS_HUMAN=$(format_staleness "$STALE_MINUTES")
        if [ -n "$ALERT_MESSAGES" ]; then
            ALERT_MESSAGES="${ALERT_MESSAGES}
"
        fi
        ALERT_MESSAGES="${ALERT_MESSAGES}🟡 ${AGENT}: Warning (${STALENESS_HUMAN} since last ping)"
    fi

    # Log incident if state changed (skip in dry-run mode)
    if [ "$DRY_RUN" -ne 1 ]; then
        if [ "$CURRENT_STATE" != "$PREV_STATE" ]; then
            # State transition detected
            case "$CURRENT_STATE" in
                warning|critical)
                    # Agent went into warning or critical state
                    if [ "$PREV_STATE" = "healthy" ] || [ "$PREV_STATE" = "unknown" ]; then
                        log_incident "$AGENT" "$CURRENT_STATE" "$STALE_MINUTES" "$AGENT_MODEL" "$AGENT_CHANNEL"
                    fi
                    ;;
                healthy)
                    # Agent recovered
                    if [ "$PREV_STATE" = "warning" ] || [ "$PREV_STATE" = "critical" ]; then
                        log_incident "$AGENT" "recovered" "0" "$AGENT_MODEL" "$AGENT_CHANNEL"
                    fi
                    ;;
            esac
        fi
        # Save current state
        save_state "$AGENT" "$CURRENT_STATE"
    fi
done

# Update status emojis in dashboard (with locking)
if acquire_lock; then
    UPDATED_CONTENT="$DASHBOARD_CONTENT"

    for AGENT in $KNOWN_AGENTS; do
        STALE_MINUTES=$(cat "${TEMP_DIR}/${AGENT}-stale")

        # Determine emoji and status text
        if [ "$STALE_MINUTES" = "unknown" ] || [ "$STALE_MINUTES" = "0" ]; then
            EMOJI="⚪"
            STATUS="Unknown"
        elif [ "$STALE_MINUTES" -gt 60 ]; then
            EMOJI="🔴"
            STATUS="Critical"
        elif [ "$STALE_MINUTES" -gt 30 ]; then
            EMOJI="🟡"
            STATUS="Warning"
        else
            EMOJI="🟢"
            STATUS="Healthy"
        fi

        # Update the Status line for this agent
        UPDATED_CONTENT=$(echo "$UPDATED_CONTENT" | awk -v agent="$AGENT" -v emoji="$EMOJI" -v status="$STATUS" '
            /^## '"$AGENT"' \(/ { in_section = 1 }
            in_section && /\*\*Status:\*\*/ {
                sub(/\*\*Status:\*\* .*/, "**Status:** " emoji " " status)
                in_section = 0
            }
            { print }
        ')
    done

    # Atomic write
    echo "$UPDATED_CONTENT" > "${DASHBOARD_PATH}.tmp"
    mv "${DASHBOARD_PATH}.tmp" "$DASHBOARD_PATH"

    release_lock
fi

# Send alerts if needed
if [ -n "$ALERT_MESSAGES" ]; then
    # Check debounce
    SHOULD_ALERT=1

    if [ -f "$ALERT_FILE" ]; then
        LAST_ALERT_EPOCH=$(cat "$ALERT_FILE" 2>/dev/null || echo "0")
        TIME_SINCE_ALERT=$((CURRENT_EPOCH - LAST_ALERT_EPOCH))

        if [ "$TIME_SINCE_ALERT" -lt "$DEBOUNCE_SECONDS" ]; then
            SHOULD_ALERT=0
            echo "Alert debounced (last alert ${TIME_SINCE_ALERT}s ago)"
        fi
    fi

    if [ "$SHOULD_ALERT" -eq 1 ]; then
        # Build alert message
        ALERT_TEXT="⚠️ Agent Health Alert

${ALERT_MESSAGES}

Dashboard: ${DASHBOARD_PATH}
Time: $(date '+%Y-%m-%d %H:%M %Z')"

        # Send the alert
        send_alert "$ALERT_TEXT"

        # Record alert time
        if [ "$DRY_RUN" -ne 1 ]; then
            echo "$CURRENT_EPOCH" > "$ALERT_FILE"
        fi

        # Critical escalation - notify again if any critical agents
        if [ -n "$CRITICAL_AGENTS" ]; then
            CRITICAL_TEXT="🚨 CRITICAL:${CRITICAL_AGENTS} unresponsive for >60 min"
            echo "$CRITICAL_TEXT"
        fi
    fi
fi

# Summary output
echo "Health check complete at $(date '+%Y-%m-%d %H:%M %Z')"
for AGENT in $KNOWN_AGENTS; do
    STALENESS=$(cat "${TEMP_DIR}/${AGENT}-stale")
    if [ "$STALENESS" = "unknown" ]; then
        echo "  $AGENT: Unknown"
    else
        STALENESS_HUMAN=$(format_staleness "$STALENESS")
        echo "  $AGENT: ${STALENESS_HUMAN} since last ping"
    fi
done

# Cleanup temp files
rm -rf "$TEMP_DIR"

exit 0
