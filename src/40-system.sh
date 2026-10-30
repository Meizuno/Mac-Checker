# ---------------------------------------------------------- заголовок ----

IS_LAPTOP=0
case "${SP_model_name:-}${SP_model_id:-}" in *MacBook*) IS_LAPTOP=1 ;; esac

MARKETING_NAME="$(ioreg -l 2>/dev/null | LC_ALL=C sed -n 's/.*"product-name" = <"\(.*\)">.*/\1/p' | head -1)"
IS_APPLE_SILICON=0
[ "$(uname -m)" = "arm64" ] && IS_APPLE_SILICON=1
UNKNOWN="$(T unknown)"

out "${C_BOLD}${C_CYAN}mac-check $VERSION${C_RESET} — $(T title)  ${C_DIM}$(date '+%Y-%m-%d %H:%M')${C_RESET}"

# ------------------------------------------------------------- система ----

section "$(T s_system)"
info "$(T model): ${C_BOLD}${MARKETING_NAME:-${SP_model_name:-$UNKNOWN}}${C_RESET} (${SP_model_id:-?}${SP_model_number:+, $SP_model_number})"
info "$(T serial): ${C_BOLD}${SP_serial:-$UNKNOWN}${C_RESET}"
info "$(T cpu): ${SP_chip:-$UNKNOWN}${SP_cpu_speed:+ @ $SP_cpu_speed}"
[ -n "${SP_t2:-}" ] && info "$(T sec_chip): $SP_t2"
info "$(T memory): ${SP_memory:-$UNKNOWN}"
info "macOS: ${SP_os:-$(sw_vers -productVersion)}"

boot_sec="$(sysctl -n kern.boottime 2>/dev/null | sed -n 's/.*{ sec = \([0-9]*\).*/\1/p')"
if [ -n "$boot_sec" ]; then
	up=$(( $(date +%s) - boot_sec ))
	info "$(T uptime $((up / 86400)) $((up % 86400 / 3600)) $((up % 3600 / 60)))"
fi

if [ "$IS_LAPTOP" = 0 ]; then
	warn "$(T not_laptop "${SP_model_name:-?}")"
fi

