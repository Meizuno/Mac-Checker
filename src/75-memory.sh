# ------------------------------------------------------------- пам'ять ----

section "$(T s_memory)"

# Залежить від того, що зараз запущено, тому лише для довідки.
mem_free="$(memory_pressure -Q 2>/dev/null | sed -n 's/.*free percentage: *\([0-9]*\)%.*/\1/p')"
if [ -n "$mem_free" ]; then
	if [ "$mem_free" -lt 10 ]; then
		info "$(T mem_free): ${mem_free}% — $(T mem_low)"
	else
		info "$(T mem_free): ${mem_free}%"
	fi
fi

swap_used="$(sysctl -n vm.swapusage 2>/dev/null | sed -n 's/.*used = *\([0-9.]*[KMG]\).*/\1/p')"
case "$swap_used" in
	"") ;;
	0.00[KMG]) info "$(T swap_none)" ;;
	*) info "$(T swap_used): $swap_used" ;;
esac

