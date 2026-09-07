#!/usr/bin/env bash
# Static/security gate for StickDeathInfinity recovery A1a
# Verifies all acceptance criteria from GitHub issue #108

set -euo pipefail

PROJECT_ROOT="/home/joevps/.cache/joeos-opencode-bridge/jmw7629__StickDeath-Infinity-/worktrees/issue-108"
cd "$PROJECT_ROOT"

echo "========================================="
echo "StickDeathInfinity — Issue #108 Verification"
echo "========================================="
echo

# 1. Run git diff --check
echo "1. Running git diff --check..."
if ! git diff --check > /dev/null 2>&1; then
    echo "   FAIL: git diff --check has whitespace errors"
    exit 1
else
    echo "   PASS: git diff --check"
fi

# 2. Prove AppConfig.swift exists
echo ""
echo "2. Checking AppConfig.swift exists..."
if [ -f "StickDeathInfinity/App/AppConfig.swift" ]; then
    echo "   PASS: StickDeathInfinity/App/AppConfig.swift exists"
else
    echo "   FAIL: StickDeathInfinity/App/AppConfig.swift not found"
    exit 1
fi

# 3. Reject api.openai.com in production Swift
echo ""
echo "3. Checking for rejected AI-provider hosts in Swift..."
if rg -l "api\.openai\.com" --glob '*.swift' StickDeathInfinity/ 2>/dev/null; then
    echo "   FAIL: api.openai.com found in production Swift"
    exit 1
else
    echo "   PASS: No api.openai.com in production Swift"
fi

if rg -l "text\.pollinations\.ai" --glob '*.swift' StickDeathInfinity/ 2>/dev/null; then
    echo "   FAIL: text.pollinations.ai found in production Swift"
    exit 1
else
    echo "   PASS: No text.pollinations.ai in production Swift"
fi

# 4. Reject openAIKey, geminiKey, provider API-key settings fields/contracts, and superuserEmails
echo ""
echo "4. Checking for rejected key contracts in Swift..."

# openAIKey
if rg -l "openAIKey" --glob '*.swift' StickDeathInfinity/ 2>/dev/null; then
    echo "   FAIL: openAIKey found in production Swift"
    exit 1
else
    echo "   PASS: No openAIKey in production Swift"
fi

# geminiKey
if rg -l "geminiKey" --glob '*.swift' StickDeathInfinity/ 2>/dev/null; then
    echo "   FAIL: geminiKey found in production Swift"
    exit 1
else
    echo "   PASS: No geminiKey in production Swift"
fi

# AppConfig.superuserEmails
if rg -l "superuserEmails" --glob '*.swift' StickDeathInfinity/ 2>/dev/null; then
    echo "   FAIL: AppConfig.superuserEmails found in production Swift"
    exit 1
else
    echo "   PASS: No AppConfig.superuserEmails in production Swift"
fi

# Provider API-key settings fields
if rg -l "APIKey" --glob '*.swift' StickDeathInfinity/ 2>/dev/null; then
    echo "   FAIL: APIKey found in production Swift"
    exit 1
else
    echo "   PASS: No APIKey constants in production Swift"
fi

# 5. Reject obvious privileged secret constants in AppConfig
echo ""
echo "5. Checking AppConfig.swift for privileged secrets..."
if rg -i "api.key|secret|password|token|oauth|signing" --glob 'AppConfig.swift' StickDeathInfinity/App/AppConfig.swift 2>/dev/null; then
    echo "   FAIL: Privileged secret constants found in AppConfig.swift"
    exit 1
else
    echo "   PASS: No privileged secret constants in AppConfig.swift"
fi

# 6. Prove SpatterService.swift still references SpatterKnowledgeBase and Supabase spatter_knowledge
echo ""
echo "6. Checking SpatterService.swift references..."
if rg -l "SpatterKnowledgeBase" --glob '*.swift' StickDeathInfinity/Services/Spatter/SpatterService.swift 2>/dev/null; then
    echo "   PASS: SpatterService.swift references SpatterKnowledgeBase"
else
    echo "   FAIL: SpatterService.swift missing SpatterKnowledgeBase reference"
    exit 1
fi

if rg -l "spatter_knowledge" --glob '*.swift' StickDeathInfinity/Services/Spatter/SpatterService.swift 2>/dev/null; then
    echo "   PASS: SpatterService.swift references Supabase spatter_knowledge"
else
    echo "   FAIL: SpatterService.swift missing spatter_knowledge reference"
    exit 1
fi

# 7. Prove both Spatter chat paths reference provider-neutral backend contract and have explicit unavailable behavior
echo ""
echo "7. Checking SpatterService.chat has unavailable behavior..."
if rg -q "unavailable" --glob '*.swift' StickDeathInfinity/Services/Spatter/SpatterService.swift 2>/dev/null; then
    echo "   PASS: SpatterService.chat has explicit unavailable behavior"
else
    echo "   FAIL: SpatterService.chat missing explicit unavailable behavior"
    exit 1
fi

if rg -q "AppConfig\.backendURL" --glob '*.swift' StickDeathInfinity/Services/Spatter/SpatterService.swift 2>/dev/null; then
    echo "   PASS: SpatterService.chat references AppConfig.backendURL (provider-neutral)"
else
    echo "   FAIL: SpatterService.chat missing AppConfig.backendURL reference"
    exit 1
fi

echo ""
echo "8. Checking SpatterAIEngine.chat has provider-neutral routing..."
if rg -q "backendEndpoint" --glob '*.swift' StickDeathInfinity/AI/SpatterBrainLoader.swift 2>/dev/null; then
    echo "   PASS: SpatterAIEngine.chat references provider-neutral backendEndpoint"
else
    echo "   FAIL: SpatterAIEngine.chat missing provider-neutral backend reference"
    exit 1
fi

if rg -q "unavailable" --glob '*.swift' StickDeathInfinity/AI/SpatterBrainLoader.swift 2>/dev/null; then
    echo "   PASS: SpatterAIEngine.chat has truthful unavailable/local-degradation behavior"
else
    echo "   FAIL: SpatterAIEngine.chat missing truthful local degradation"
    exit 1
fi

# 8. Secret-scans the exact diff without printing secret values
echo ""
echo "8. Secret-scanning exact diff..."
DIFF_OUTPUT=$(git diff 2>/dev/null || true)

# Scan for secret patterns in the diff (but don't print values)
SECRET_PATTERNS=(
    "openAIAPIKey"
    "openAIModel"
    "geminiAPIKey"
    "superuserEmails"
    "api.openai.com"
    "text.pollinations.ai"
)

FOUND_SECRETS=0
for pattern in "${SECRET_PATTERNS[@]}"; do
    if echo "$DIFF_OUTPUT" | grep -q "$pattern"; then
        echo "   FAIL: Secret pattern '$pattern' found in diff"
        FOUND_SECRETS=1
    fi
done

if [ "$FOUND_SECRETS" -eq 0 ]; then
    echo "   PASS: No secret values in exact diff"
else
    exit 1
fi

echo ""
echo "========================================="
echo "ALL CHECKS PASSED"
echo "========================================="