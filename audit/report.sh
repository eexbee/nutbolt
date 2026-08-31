#!/usr/bin/env bash
# =============================================================================
# audit/report.sh - Console output + file report (reports/security-audit.txt)
# =============================================================================

audit_print_console() {
    echo ""
    printf '\033[1m  %-42s %s\033[0m\n' "CHECK" "RESULT"
    local i id mark
    for i in "${!AUDIT_CHECK_IDS[@]}"; do
        if [[ "${AUDIT_CHECK_RESULTS[$i]}" == "1" ]]; then
            printf '  \033[0;32m%-42s\033[0m %s\n' "${AUDIT_CHECK_DESCS[$i]}" "PASS"
        else
            printf '  \033[0;31m%-42s\033[0m \033[0;31m%s\033[0m\n' "${AUDIT_CHECK_DESCS[$i]}" "FAIL"
        fi
    done
    echo ""
    local color
    color="$(audit_grade_color "$AUDIT_SCORE")"
    printf '  \033[1mSecurity Score: %s%d/100\033[0m  (%s)  passed=%d failed=%d\n' \
        "$color" "$AUDIT_SCORE" "$(audit_score_rating "$AUDIT_SCORE")" "$AUDIT_PASSED" "$AUDIT_FAILED"
    printf '\033[0m'
}

audit_write_report() {
    local report_dir="$FRAMEWORK_ROOT/reports"
    mkdir -p "$report_dir"
    local report="$report_dir/security-audit.txt"

    {
        echo "================================================================"
        echo "  SERVER SECURITY AUDIT REPORT"
        echo "================================================================"
        echo "  Host     : $(hostname)"
        echo "  OS       : $OS_DESC"
        echo "  Date     : $(date '+%Y-%m-%d %H:%M:%S %Z')"
        echo "  Kernel   : $(uname -r)"
        echo "================================================================"
        echo ""
        printf '%-4s %-44s %-6s %-4s %s\n' "#" "CHECK" "STATE" "PTS" "DETAILS"
        printf '%s\n' "-----------------------------------------------------------------------------"
        local i n=1
        for i in "${!AUDIT_CHECK_IDS[@]}"; do
            local state="FAIL"
            [[ "${AUDIT_CHECK_RESULTS[$i]}" == "1" ]] && state="PASS"
            printf '%-4s %-44s %-6s %-4s %s\n' \
                "$n" "${AUDIT_CHECK_DESCS[$i]}" "$state" \
                "${AUDIT_CHECK_WEIGHTS[$i]}/${AUDIT_CHECK_WEIGHTS[$i]}" "${AUDIT_CHECK_DETAILS[$i]}"
            n=$((n+1))
        done
        printf '%s\n' "-----------------------------------------------------------------------------"
        echo ""
        echo "  SECURITY SCORE: ${AUDIT_SCORE}/100  [$(audit_score_rating "$AUDIT_SCORE")]"
        echo "  Passed: $AUDIT_PASSED    Failed: $AUDIT_FAILED    Maximum: $AUDIT_MAX"
        echo ""
        if (( AUDIT_FAILED > 0 )); then
            echo "  RECOMMENDED ACTIONS:"
            for i in "${!AUDIT_CHECK_IDS[@]}"; do
                if [[ "${AUDIT_CHECK_RESULTS[$i]}" != "1" ]]; then
                    echo "    - Fix: ${AUDIT_CHECK_DESCS[$i]} (${AUDIT_CHECK_DETAILS[$i]})"
                fi
            done
            echo ""
        fi
        echo "  Next audit file: $report_dir/security-audit-$(date +%Y%m%d-%H%M%S).txt"
        echo "================================================================"
    } > "$report"

    cp "$report" "$report_dir/security-audit-$(date +%Y%m%d-%H%M%S).txt"
    log_ok "Report written: $report"
}
