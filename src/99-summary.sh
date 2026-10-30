# -------------------------------------------------------------- підсумок ----

section "$(T s_summary)"
out "  ${C_GREEN}✔ $N_OK${C_RESET}   ${C_YELLOW}▲ $N_WARN${C_RESET}   ${C_RED}✖ $N_FAIL${C_RESET}"

if [ -n "$ISSUES" ]; then
	out ""
	printf '%s' "$ISSUES" | while IFS='|' read -r lvl msg; do
		[ -z "$lvl" ] && continue
		if [ "$lvl" = FAIL ]; then out "  ${C_RED}✖${C_RESET} $msg"; else out "  ${C_YELLOW}▲${C_RESET} $msg"; fi
	done
fi

out ""
if [ "$N_FAIL" -gt 0 ]; then
	out "  ${C_BOLD}${C_RED}$(T verdict_fail)${C_RESET}"
elif [ "$N_WARN" -gt 0 ]; then
	out "  ${C_BOLD}${C_YELLOW}$(T verdict_warn)${C_RESET}"
else
	out "  ${C_BOLD}${C_GREEN}$(T verdict_ok)${C_RESET}"
fi

section "$(T s_manual_check)"
info "$(T chk_warranty): https://checkcoverage.apple.com ($(T serial_lower): ${SP_serial:-?})"
info "$(T chk_serial)"
info "$(T chk_diag)"
info "$(T chk_case)"
info "$(T chk_liquid)"
info "$(T chk_ports)"
info "$(T chk_trackpad)"
info "$(T chk_seller)"
hint "$(T chk_erase)"
[ "$(id -u)" != 0 ] && hint "$(T chk_sudo)"

if [ -n "$REPORT_FILE" ]; then
	out ""
	out "$(T report_saved): $REPORT_FILE"
fi

[ "$N_FAIL" -eq 0 ]
