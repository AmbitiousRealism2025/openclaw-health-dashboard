# Agent Health Incident Log

Append-only log of agent health incidents. This file is automatically updated by `check-agent-health.sh` when agents transition between health states.

## Incident Types

| Type | Emoji | Condition |
|------|-------|-----------|
| Warning | 🟡 | Agent hasn't pinged in 30-60 minutes |
| Critical | 🔴 | Agent hasn't pinged in >60 minutes |
| Recovered | 🟢 | Agent returned to healthy state after warning/critical |

---

## Incident History

