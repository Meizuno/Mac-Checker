# ------------------------------------------------------------- батарея ----

section "$(T s_battery)"

if [ "$IS_LAPTOP" = 1 ] || [ -n "${SP_bat_present:-}" ]; then
	cycles="${SP_bat_cycles:-$(bat_field CycleCount)}"
	design_cycles="$(bat_field DesignCycleCount9C)"
	design_cycles="${design_cycles:-1000}"
	design_cap="$(bat_field DesignCapacity)"
	raw_max="$(bat_field AppleRawMaxCapacity)"
	[ -z "$raw_max" ] && raw_max="$(bat_field NominalChargeCapacity)"

	maxpct="$(printf '%s' "${SP_bat_maxcap:-}" | tr -dc '0-9')"
	if [ -z "$maxpct" ] && [ -n "$design_cap" ] && [ -n "$raw_max" ] && [ "$design_cap" -gt 0 ]; then
		maxpct=$(( raw_max * 100 / design_cap ))
	fi

	if [ -z "$cycles" ] && [ -z "$maxpct" ]; then
		fail "$(T bat_missing)"
	else
		if [ -n "$cycles" ]; then
			cyc="$(T cycles "$cycles" "$design_cycles")"
			if [ "$cycles" -ge "$design_cycles" ]; then
				fail "$cyc — $(T cycles_over)"
			elif [ "$cycles" -ge $(( design_cycles * 7 / 10 )) ]; then
				warn "$cyc — $(T cycles_worn)"
			else
				ok "$cyc"
			fi
		fi

		if [ -n "$maxpct" ]; then
			cap="$(T maxcap): ${maxpct}%"
			if [ -n "$design_cap" ] && [ -n "$raw_max" ]; then
				cap="$cap ($(T mah "$raw_max" "$design_cap"))"
			fi
			if [ "$maxpct" -lt 80 ]; then
				fail "$cap — $(T replace)"
			elif [ "$maxpct" -lt 87 ]; then
				warn "$cap"
			else
				ok "$cap"
			fi
		fi

		case "${SP_bat_health:-}" in
			"") ;;
			Good|Normal) ok "$(T bat_cond): $SP_bat_health" ;;
			*) fail "$(T bat_cond): $SP_bat_health" ;;
		esac

		if [ -n "$cycles" ] && [ -n "$maxpct" ] && [ "$cycles" -lt 30 ] && [ "$maxpct" -lt 95 ]; then
			warn "$(T bat_fake)"
		fi
	fi

	[ -n "${SP_bat_charge:-}" ] && info "$(T charge_now): ${SP_bat_charge}%"
	[ -n "${SP_bat_serial:-}" ] && info "$(T bat_serial): $SP_bat_serial"

	if [ "${SP_ac_connected:-}" = "TRUE" ]; then
		ok "$(T ac_on)${SP_ac_watts:+: ${SP_ac_watts} $(T watt)}${SP_ac_name:+ ($SP_ac_name)}"
		[ "${SP_bat_charging:-}" = "TRUE" ] && info "$(T charging)"
	else
		info "$(T ac_off)"
	fi
else
	info "$(T no_battery)"
fi

