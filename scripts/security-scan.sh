#!/bin/bash
# ═══════════════════════════════════════════════════════════════════
# Security/Source Scan — v16 recovery gate
# Catches forbidden patterns that previous scans missed.
# ═══════════════════════════════════════════════════════════════════

set -euo pipefail

FAIL=0
WARN=0
SCAN_DIR="${1:-.}"

echo "═══════════════════════════════════════════════════════════════"
echo " Security/Source Scan — Recovery Gate v16"
echo " Scan directory: $SCAN_DIR"
echo "═══════════════════════════════════════════════════════════════"

# ─── 1. Forbidden provider-key properties/inputs ───
echo ""
echo "─── 1. Provider-key properties/inputs ───"
if grep -rn --include='*.swift' -E '(openAIAPIKey|openAIKey|geminiAPIKey|anthropicKey|pollinationsKey)\s*[:=]' "$SCAN_DIR/StickDeathInfinity/" 2>/dev/null | grep -v '// ' | grep -v 'AppConfig\.' | grep -v 'SpatterBotService\|SpatterCCSettings'; then
    echo "  WARN: Direct provider-key assignment found (non-AppConfig)"
    WARN=$((WARN + 1))
else
    echo "  PASS: No forbidden provider-key assignments"
fi

# ─── 2. Direct provider hosts ───
echo ""
echo "─── 2. Direct provider hosts ───"
if grep -rn --include='*.swift' -E 'https://api\.(openai|google|anthropic|pollinations)\.(com|ai)' "$SCAN_DIR/StickDeathInfinity/" 2>/dev/null | grep -v '// ' | grep -v 'SpatterAIEngine'; then
    echo "  FAIL: Direct provider host found"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: No direct provider hosts (except embedded AI engine)"
fi

# ─── 3. Known secret/service-role literal patterns ───
echo ""
echo "─── 3. Secret/service-role literal patterns ───"
if grep -rn --include='*.swift' -E '(service_role|supabase_service_role|sk_live|sk_test|pk_live|pk_test)\s*[:=]' "$SCAN_DIR/StickDeathInfinity/" 2>/dev/null | grep -v '// '; then
    echo "  FAIL: Secret/service-role literal found"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: No secret/service-role literals"
fi

# ─── 4. Placeholder/fallback service URLs ───
echo ""
echo "─── 4. Placeholder/fallback service URLs ───"
if grep -rn --include='*.swift' -E 'placeholder\.(supabase\.co|example\.com)' "$SCAN_DIR/StickDeathInfinity/" 2>/dev/null | grep -v '// '; then
    echo "  FAIL: Placeholder service URL found"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: No placeholder service URLs"
fi

# ─── 5. Placeholder keys ───
echo ""
echo "─── 5. Placeholder keys ───"
if grep -rn --include='*.swift' -E '(placeholder-key|placeholder_key|YOUR_API_KEY|YOUR_KEY_HERE)' "$SCAN_DIR/StickDeathInfinity/" 2>/dev/null | grep -v '// '; then
    echo "  FAIL: Placeholder key found"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: No placeholder keys"
fi

# ─── 6. Client-local email-based admin/superadmin ───
echo ""
echo "─── 6. Client-local admin email authorization ───"
if grep -rn --include='*.swift' -E '(superuserEmails|adminEmails|\.contains\(email)' "$SCAN_DIR/StickDeathInfinity/" 2>/dev/null | grep -v '// '; then
    echo "  FAIL: Client-local email-based admin authorization found"
    FAIL=$((FAIL + 1))
else
    echo "  PASS: No client-local email-based admin authorization"
fi

# ─── 7. DeviceStorageManager legacy animation writer/deleter ───
echo ""
echo "─── 7. DeviceStorageManager legacy write patterns ───"
DSCOUNT=$(grep -rn --include='*.swift' 'DeviceStorageManager' "$SCAN_DIR/StickDeathInfinity/" 2>/dev/null | grep -v '// ' | grep -v 'Storage/DeviceStorageManager.swift' | wc -l || true)
echo "  INFO: DeviceStorageManager references: $DSCOUNT"
if grep -rn --include='*.swift' 'deleteAnimation' "$SCAN_DIR/StickDeathInfinity/" 2>/dev/null | grep -v 'Storage/DeviceStorageManager.swift' | grep -v '// '; then
    echo "  WARN: deleteAnimation called outside DeviceStorageManager"
    WARN=$((WARN + 1))
else
    echo "  PASS: No external deleteAnimation calls"
fi

# ─── 8. AppConfig tracking ───
echo ""
echo "─── 8. AppConfig property audit ───"
if [ -f "$SCAN_DIR/StickDeathInfinity/App/AppConfig.swift" ]; then
    echo "  AppConfig.swift exists"
    # Check for fake fallback
    if grep -n 'placeholder' "$SCAN_DIR/StickDeathInfinity/App/AppConfig.swift" 2>/dev/null | grep -v '// ' | grep -v 'contains'; then
        echo "  FAIL: Placeholder fallback in AppConfig"
        FAIL=$((FAIL + 1))
    else
        echo "  PASS: No placeholder fallback in AppConfig"
    fi
else
    echo "  FAIL: AppConfig.swift not found"
    FAIL=$((FAIL + 1))
fi

# ─── 9. SDCore local wiring ───
echo ""
echo "─── 9. SDCore local wiring ───"
if [ -f "$SCAN_DIR/project.yml" ]; then
    if grep -q 'SDCore' "$SCAN_DIR/project.yml" 2>/dev/null; then
        echo "  PASS: SDCore referenced in project.yml"
    else
        echo "  FAIL: SDCore not referenced in project.yml"
        FAIL=$((FAIL + 1))
    fi
else
    echo "  WARN: project.yml not found"
    WARN=$((WARN + 1))
fi

if [ -f "$SCAN_DIR/SDCore/Package.swift" ]; then
    echo "  PASS: SDCore/Package.swift exists"
else
    echo "  FAIL: SDCore/Package.swift not found"
    FAIL=$((FAIL + 1))
fi

# ─── 10. Production Spatter import/transport ───
echo ""
echo "─── 10. Production Spatter transport seam ───"
if grep -q 'import SDCore' "$SCAN_DIR/StickDeathInfinity/Services/Spatter/SpatterService.swift" 2>/dev/null; then
    echo "  PASS: SpatterService imports SDCore"
else
    echo "  FAIL: SpatterService does not import SDCore"
    FAIL=$((FAIL + 1))
fi

if grep -q 'TransportFactory\|SpatterTransport' "$SCAN_DIR/StickDeathInfinity/Services/Spatter/SpatterService.swift" 2>/dev/null; then
    echo "  PASS: SpatterService uses transport seam"
else
    echo "  FAIL: SpatterService does not use transport seam"
    FAIL=$((FAIL + 1))
fi

# ─── Summary ───
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo " Scan Complete"
echo " FAIL: $FAIL"
echo " WARN: $WARN"
echo "═══════════════════════════════════════════════════════════════"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
