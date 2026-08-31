#!/usr/bin/env bash
# =============================================================================
# audit/scoring.sh - Score calculation from registered checks
# =============================================================================

audit_score() { # sets AUDIT_SCORE (0-100), AUDIT_MAX, AUDIT_PASSED, AUDIT_FAILED
    AUDIT_MAX=0
    AUDIT_SCORE=0
    AUDIT_PASSED=0
    AUDIT_FAILED=0
    local i
    for i in "${!AUDIT_CHECK_IDS[@]}"; do
        AUDIT_MAX=$(( AUDIT_MAX + AUDIT_CHECK_WEIGHTS[$i] ))
        if [[ "${AUDIT_CHECK_RESULTS[$i]}" == "1" ]]; then
            AUDIT_SCORE=$(( AUDIT_SCORE + AUDIT_CHECK_WEIGHTS[$i] ))
            AUDIT_PASSED=$(( AUDIT_PASSED + 1 ))
        else
            AUDIT_FAILED=$(( AUDIT_FAILED + 1 ))
        fi
    done
}

audit_score_rating() { # rating text for a score
    local s="$1"
    if   (( s >= 90 )); then echo "EXCELLENT"
    elif (( s >= 75 )); then echo "GOOD"
    elif (( s >= 50 )); then echo "FAIR"
    else                     echo "POOR"
    fi
}

audit_grade_color() {
    local s="$1"
    if   (( s >= 75 )); then printf '\033[0;32m'
    elif (( s >= 50 )); then printf '\033[0;33m'
    else                     printf '\033[0;31m'
    fi
}
