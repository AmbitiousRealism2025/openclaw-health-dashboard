# Agent Health Dashboard

A lightweight, dependency-free health monitoring system for tracking agent status. No database, no external services — just markdown and cron.

## Overview

- **Dashboard**: Human-readable markdown file showing all agent statuses
- **Update Script**: Called by each agent on heartbeat
- **Monitoring Script**: Cron job that alerts when agents go stale
- **Incident Log**: Append-only log of health state transitions

## Status Indicators

| Status | Emoji | Condition |
|--------|-------|-----------|
| Healthy | 🟢 | Last ping < 30 min |
| Warning | 🟡 | Last ping 30-60 min |
| Critical | 🔴 | Last ping > 60 min |
| Unknown | ⚪ | No data / parse error |

## Incident Logging

When the monitoring script detects a state transition (healthy → warning/critical, or warning/critical → healthy), it logs the incident to `agent-health-incidents.md`.

### Incident Types

| Type | Emoji | Description |
|------|-------|-------------|
| Warning | 🟡 | Agent hasn't pinged in 30-60 minutes |
| Critical | 🔴 | Agent hasn't pinged in >60 minutes |
| Recovered | 🟢 | Agent returned to healthy after being in warning/critical |

### Example Log Entries

```markdown
## 2026-02-13T10:45:00 EST
- 🟡 Leto: Warning (35m stale)
- Model: minimax/minimax-m2.5
- Channel: telegram

## 2026-02-13T11:15:00 EST
- 🟢 Leto: Recovered

## 2026-02-13T14:30:00 EST
- 🔴 Stilgar: Critical (1h 15m stale)
- Model: anthropic/claude-opus-4-6
- Channel: telegram
```

### State Tracking

State is persisted in `/tmp/agent-health-state/` to detect transitions between runs.

## Quick Start

### 1. Clone the Repository

```bash
gh repo clone ambitiousrealism2025/openclaw-health-dashboard
cd openclaw-health-dashboard
```

### 2. Make Scripts Executable

```bash
chmod +x update-health-dashboard.sh check-agent-health.sh
```

### 3. Test the Update Script

```bash
# Test with mock data
./update-health-dashboard.sh "Stilgar" "Bear"

# Check the dashboard
cat agent-health.md
```

### 4. Set Up Cron for Monitoring

```bash
# Edit crontab
crontab -e

# Add this line (runs every 15 minutes)
*/15 * * * * ~/path/to/check-agent-health.sh >> /tmp/agent-health-monitor.log 2>&1
```

## Integration

### Adding to Agent Heartbeat Hooks

Add this to each agent's heartbeat hook configuration:

```bash
# In your agent's heartbeat hook:
/path/to/update-health-dashboard.sh "AgentName" "Creature"
```

**Example for Stilgar:**
```bash
~/openclaw-health-dashboard/update-health-dashboard.sh "Stilgar" "Bear"
```

### Environment Variables

The update script uses these environment variables (optional):

| Variable | Description | Default |
|----------|-------------|---------|
| `MODEL` | Model identifier | From `openclaw status` |
| `CHANNEL` | Communication channel | `telegram` |

## File Structure

```
openclaw-health-dashboard/
├── agent-health.md              # Dashboard file
├── agent-health-incidents.md    # Incident log (append-only)
├── update-health-dashboard.sh   # Agent heartbeat hook
├── check-agent-health.sh        # Monitoring cron script
├── README.md                    # This file
├── PLAN.md                      # Original implementation plan
└── tests/                       # Validation tests
    ├── test-update.sh
    ├── test-monitor.sh
    ├── test-locking.sh
    └── test-incident-log.sh
```

## Configuration

### Alerting

Alerts are sent via `openclaw gateway wake`:

```bash
openclaw gateway wake --text "Alert message" --mode now
```

### Alert Debounce

Alerts are debounced for 30 minutes to prevent spam. The last alert timestamp is stored in:

```
/tmp/agent-health-last-alert
```

### Uptime Tracking

Each agent's uptime is tracked via a start-time file:

```
/tmp/Duncan-uptime-start
/tmp/Leto-uptime-start
/tmp/Stilgar-uptime-start
```

To reset uptime, delete these files. They'll be recreated on the next heartbeat.

## Monitoring Script Options

```bash
# Normal run (sends alerts)
./check-agent-health.sh

# Dry run (no alerts, just output)
./check-agent-health.sh --dry-run
```

## Race Condition Handling

The update script uses `flock` for file locking:

- 10 second timeout
- Non-blocking — if lock unavailable, skips update gracefully
- Lock file: `/tmp/agent-health-dashboard.lock`

## Troubleshooting

### Dashboard not updating

1. Check script is executable: `ls -la update-health-dashboard.sh`
2. Check agent name matches exactly (case-sensitive)
3. Check lock file isn't stale: `rm /tmp/agent-health-dashboard.lock`

### Alerts not sending

1. Verify `openclaw` CLI is available: `which openclaw`
2. Test alert manually: `openclaw gateway wake --text "Test" --mode now`
3. Check debounce hasn't blocked: `cat /tmp/agent-health-last-alert`

### Wrong timestamps

The script uses your system timezone. Ensure system time is correct.

## Known Agents

| Agent | Creature | Description |
|-------|----------|-------------|
| Duncan | Raven | Primary orchestrator |
| Leto | Lion | Strategic planner |
| Stilgar | Bear | Technical implementer |

To add new agents, edit `KNOWN_AGENTS` array in `check-agent-health.sh` and add a section to `agent-health.md`.

## License

MIT

## Origin

Built by Muad'Dib (GLM-5 Atreides team) based on plans from Leto (architecture) and Stilgar (technical specs).
