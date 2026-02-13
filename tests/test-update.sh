#!/bin/bash
# test-update.sh
# Tests that update-health-dashboard.sh writes correctly

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
UPDATE_SCRIPT="${SCRIPT_DIR}/update-health-dashboard.sh"
DASHBOARD_PATH="${SCRIPT_DIR}/agent-health.md"
BACKUP_PATH="/tmp/agent-health-backup.md"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo -e "${GREEN}✓ PASS:${NC} $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}✗ FAIL:${NC} $1"
    ((TESTS_FAILED++))
}

# Backup original dashboard
if [ -f "$DASHBOARD_PATH" ]; then
    cp "$DASHBOARD_PATH" "$BACKUP_PATH"
fi

# Cleanup function
cleanup() {
    if [ -f "$BACKUP_PATH" ]; then
        mv "$BACKUP_PATH" "$DASHBOARD_PATH"
    fi
    # Clean up test uptime files
    rm -f /tmp/TestAgent-uptime-start
}
trap cleanup EXIT

echo "=== Testing update-health-dashboard.sh ==="
echo ""

# Test 1: Script exists and is executable
echo "Test 1: Script exists and is executable"
if [ -x "$UPDATE_SCRIPT" ]; then
    pass "Script is executable"
else
    fail "Script is not executable"
fi

# Test 2: Script requires arguments
echo ""
echo "Test 2: Script requires arguments"
OUTPUT=$("$UPDATE_SCRIPT" 2>&1 || true)
if echo "$OUTPUT" | grep -q "Usage"; then
    pass "Script shows usage when no args provided"
else
    fail "Script should show usage when no args provided"
fi

# Test 3: Script updates dashboard
echo ""
echo "Test 3: Script updates dashboard with agent info"
# Set mock environment
export MODEL="test-model-v1"
export CHANNEL="test-channel"

"$UPDATE_SCRIPT" "TestAgent" "TestCreature"

if grep -q "TestAgent" "$DASHBOARD_PATH"; then
    pass "Agent name appears in dashboard"
else
    fail "Agent name not found in dashboard"
fi

if grep -q "TestCreature" "$DASHBOARD_PATH"; then
    pass "Creature appears in dashboard"
else
    fail "Creature not found in dashboard"
fi

if grep -q "test-model-v1" "$DASHBOARD_PATH"; then
    pass "Model appears in dashboard"
else
    fail "Model not found in dashboard"
fi

# Test 4: Last Updated timestamp changes
echo ""
echo "Test 4: Last Updated timestamp is current"
TIMESTAMP=$(grep "Last Updated" "$DASHBOARD_PATH" | head -1)
TODAY=$(date +"%Y-%m-%d")
if echo "$TIMESTAMP" | grep -q "$TODAY"; then
    pass "Timestamp contains today's date"
else
    fail "Timestamp doesn't contain today's date"
fi

# Test 5: Uptime file created
echo ""
echo "Test 5: Uptime tracking file created"
if [ -f "/tmp/TestAgent-uptime-start" ]; then
    pass "Uptime file created"
else
    fail "Uptime file not created"
fi

# Test 6: Repeated update preserves data
echo ""
echo "Test 6: Repeated update works correctly"
sleep 1  # Ensure different timestamp
"$UPDATE_SCRIPT" "TestAgent" "TestCreature"

AGENT_COUNT=$(grep -c "## TestAgent" "$DASHBOARD_PATH" || true)
if [ "$AGENT_COUNT" -eq 1 ]; then
    pass "Only one section per agent (no duplicates)"
else
    fail "Duplicate sections found: $AGENT_COUNT"
fi

# Test 7: Multiple agents work
echo ""
echo "Test 7: Multiple agents can update"
"$UPDATE_SCRIPT" "SecondAgent" "SecondCreature"

if grep -q "SecondAgent" "$DASHBOARD_PATH"; then
    pass "Second agent added"
else
    fail "Second agent not added"
fi

# Summary
echo ""
echo "=== Test Summary ==="
echo -e "Passed: ${GREEN}${TESTS_PASSED}${NC}"
echo -e "Failed: ${RED}${TESTS_FAILED}${NC}"

if [ "$TESTS_FAILED" -eq 0 ]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed.${NC}"
    exit 1
fi
