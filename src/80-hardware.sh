# ------------------------------------------------------------- залізо ----

section "$(T s_hw)"

i=1
while [ "$i" -le "${SP_gpu_count:-0}" ]; do
	var="SP_gpu_$i"
	IFS='|' read -r g_name g_cores g_vram <<EOF
${!var}
EOF
	info "$(T graphics): $g_name${g_cores:+, $g_cores $(T cores)}${g_vram:+, $g_vram}"
	i=$((i + 1))
done

has_internal=0
i=1
while [ "$i" -le "${SP_disp_count:-0}" ]; do
	var="SP_disp_$i"
	IFS='|' read -r s_name s_res s_int <<EOF
${!var}
EOF
	if [ "$s_int" = 1 ]; then
		has_internal=1
		ok "$(T disp_int): $s_name${s_res:+, $s_res}"
	else
		info "$(T disp_ext): $s_name${s_res:+, $s_res}"
	fi
	i=$((i + 1))
done
if [ "$IS_LAPTOP" = 1 ] && [ "$has_internal" = 0 ]; then
	warn "$(T disp_none)"
fi

if [ -n "${SP_cameras:-}" ]; then
	ok "$(T camera): $SP_cameras"
elif [ "$IS_LAPTOP" = 1 ]; then
	fail "$(T camera_none)"
else
	info "$(T camera_none)"
fi

if [ -n "${SP_speakers:-}" ]; then
	ok "$(T speakers): $SP_speakers"
elif [ "$IS_LAPTOP" = 1 ]; then
	fail "$(T speakers_none)"
fi
if [ -n "${SP_mics:-}" ]; then
	ok "$(T mic): $SP_mics"
elif [ "$IS_LAPTOP" = 1 ]; then
	fail "$(T mic_none)"
fi

if networksetup -listallhardwareports 2>/dev/null | grep -q 'Wi-Fi'; then
	ok "$(T wifi_ok)"
else
	fail "$(T wifi_none)"
fi

if [ -n "${SP_bt_chip:-}" ]; then
	bt_on=""
	[ "${SP_bt_state:-}" = attrib_on ] && bt_on=", $(T bt_on)"
	ok "Bluetooth: $SP_bt_chip$bt_on"
else
	fail "$(T bt_none)"
fi

