# ------------------------------------------------ блокування та безпека ----

section "$(T s_locks)"

case "${SP_activation_lock:-}" in
	activation_lock_disabled) ok "$(T al_off)" ;;
	activation_lock_enabled)
		fail "$(T al_on)"
		hint "$(T al_on_hint1)"
		hint "$(T al_on_hint2)" ;;
	*)
		if nvram fmm-mobileme-token-FMM >/dev/null 2>&1; then
			fail "$(T fmm_on)"
		else
			info "$(T al_na)"
		fi ;;
esac

enroll="$(profiles status -type enrollment 2>/dev/null)"
if [ -z "$enroll" ]; then
	info "$(T mdm_na)"
else
	dep="$(printf '%s' "$enroll" | sed -n 's/.*Enrolled via DEP: *//p')"
	mdm="$(printf '%s' "$enroll" | sed -n 's/.*MDM enrollment: *//p')"
	if printf '%s' "$dep" | grep -qi '^yes'; then
		fail "$(T dep_yes)"
	else
		ok "$(T dep_no)"
	fi
	if printf '%s' "$mdm" | grep -qi '^yes'; then
		fail "$(T mdm_yes "$mdm")"
	else
		ok "$(T mdm_no)"
	fi
fi

if [ "$(id -u)" = 0 ]; then
	nprof="$(profiles list -all 2>/dev/null | grep -c 'profileIdentifier')"
	if [ "${nprof:-0}" -gt 0 ]; then
		warn "$(T profiles_yes "$nprof")"
	else
		ok "$(T profiles_no)"
	fi
	if [ "$IS_APPLE_SILICON" = 0 ] && command -v firmwarepasswd >/dev/null 2>&1; then
		if firmwarepasswd -check 2>/dev/null | grep -qi 'Enabled: Yes'; then
			fail "$(T fw_yes)"
		else
			ok "$(T fw_no)"
		fi
	fi
fi

icloud="$(defaults read MobileMeAccounts Accounts 2>/dev/null | sed -n 's/.*AccountID = "\{0,1\}\([^";]*\)"\{0,1\};.*/\1/p' | head -1)"
if [ -n "$icloud" ]; then
	warn "$(T icloud_yes "$(printf '%s' "$icloud" | sed 's/^\(..\)[^@]*/\1***/')")"
else
	# У нових macOS дані акаунтів закриті TCC, тож відсутність запису ще нічого не означає.
	info "$(T icloud_check)"
fi

if csrutil status 2>/dev/null | grep -q 'enabled'; then
	ok "$(T sip_on)"
else
	warn "$(T sip_off)"
fi

if fdesetup status 2>/dev/null | grep -q 'On'; then
	info "$(T fv_on)"
else
	info "$(T fv_off)"
fi

