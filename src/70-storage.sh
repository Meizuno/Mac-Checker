# --------------------------------------------------------- накопичувач ----

section "$(T s_storage)"

if [ "${SP_disk_count:-0}" -eq 0 ]; then
	warn "$(T disk_none)"
else
	i=1
	while [ "$i" -le "$SP_disk_count" ]; do
		var="SP_disk_$i"
		IFS='|' read -r d_model d_size d_smart d_medium <<EOF
${!var}
EOF
		case "$d_smart" in
			Verified) ok "$d_model, $d_size — SMART: Verified" ;;
			Failing)  fail "$d_model, $d_size — SMART: FAILING, $(T smart_failing)" ;;
			"")       warn "$d_model, $d_size — $(T smart_na)" ;;
			*)        warn "$d_model, $d_size — SMART: $d_smart" ;;
		esac
		i=$((i + 1))
	done
fi

if command -v smartctl >/dev/null 2>&1; then
	smart="$(smartctl -a disk0 2>/dev/null)"
	used="$(printf '%s\n' "$smart" | sed -n 's/^Percentage Used: *//p')"
	written="$(printf '%s\n' "$smart" | sed -n 's/^Data Units Written: *[0-9,]* *\[\(.*\)\]/\1/p')"
	if [ -n "$used" ]; then
		used_n="$(printf '%s' "$used" | tr -dc '0-9')"
		wear="$(T ssd_wear): $used"
		if [ "${used_n:-0}" -ge 80 ]; then fail "$wear"
		elif [ "${used_n:-0}" -ge 30 ]; then warn "$wear"
		else ok "$wear"; fi
		[ -n "$written" ] && info "$(T ssd_written): $written"
	elif [ "$(id -u)" != 0 ]; then
		hint "$(T smart_sudo)"
	else
		hint "$(T smart_nodata)"
	fi
else
	hint "$(T smart_install)"
fi

free_h="$(df -h / 2>/dev/null | awk 'NR==2 {print $4 "|" $2}')"
[ -n "$free_h" ] && info "$(T sys_volume "${free_h%|*}" "${free_h#*|}")"

