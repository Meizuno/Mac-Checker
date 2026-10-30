# --------------------------------------------------------- стабільність ----

section "$(T s_stability)"

panics="$(find /Library/Logs/DiagnosticReports -maxdepth 2 -iname '*panic*' 2>/dev/null)"
npanics=0
[ -n "$panics" ] && npanics="$(printf '%s\n' "$panics" | wc -l | tr -d ' ')"
if [ "$npanics" -eq 0 ]; then
	ok "$(T panics_none)"
else
	last="$(ls -t $panics 2>/dev/null | head -1)"
	last_date="$(stat -f '%Sm' -t '%Y-%m-%d' "$last" 2>/dev/null)"
	kp="$(T panics "$npanics" "$last_date")"
	if [ "$npanics" -ge 3 ]; then
		fail "$kp — $(T panics_hw)"
	else
		warn "$kp"
	fi
fi
hint "$(T panics_hint)"

therm="$(pmset -g therm 2>/dev/null | grep -i 'level' | grep -vi 'no .* recorded')"
if [ -n "$therm" ]; then
	warn "$(T therm_yes): $(printf '%s' "$therm" | head -1 | sed 's/^ *//')"
else
	ok "$(T therm_no)"
fi

