# --------------------------------------------------------- ручні тести ----

manual_result() {
	if ask_yn "  $(T works_q "$1")"; then
		ok "$1 — $(T checked_ok)"
	else
		fail "$1 — $(T checked_fail)"
	fi
}

test_keyboard() {
	local remaining="\`1234567890-=qwertyuiop[]asdfghjkl;'\\zxcvbnm,./"
	local special_left="SPACE ENTER TAB BACKSPACE ← → ↑ ↓"
	local left_label="$(T kb_left)"
	local k rest old_stty
	out ""
	out "${C_BOLD}$(T kb_title)${C_RESET} $(T kb_intro)"
	out "${C_DIM}$(T kb_hint)${C_RESET}"
	old_stty="$(stty -g < /dev/tty)"
	stty -icanon -echo < /dev/tty
	while :; do
		printf '\r\033[K  %s: %s %s' "$left_label" "$remaining" "$special_left" > /dev/tty
		if [ -z "$remaining" ] && [ -z "$special_left" ]; then break; fi
		IFS= read -rsn1 -d '' k < /dev/tty || break
		case "$k" in
			$'\033')
				rest=""
				IFS= read -rsn2 -t 1 rest < /dev/tty
				case "$rest" in
					"[A") special_left="${special_left/↑/}" ;;
					"[B") special_left="${special_left/↓/}" ;;
					"[C") special_left="${special_left/→/}" ;;
					"[D") special_left="${special_left/←/}" ;;
					"") break ;;
				esac ;;
			" ") special_left="${special_left/SPACE/}" ;;
			$'\n'|$'\r') special_left="${special_left/ENTER/}" ;;
			$'\t') special_left="${special_left/TAB/}" ;;
			$'\177'|$'\b') special_left="${special_left/BACKSPACE/}" ;;
			*)
				# Shift-символи зводимо до базової клавіші; "-" в кінці, щоб tr не прочитав його як діапазон.
				k="$(printf '%s' "$k" | tr 'A-Z~!@#$%^&*()+{}:"|<>?_' 'a-z`1234567890=[];'"'"'\\,./-')"
				remaining="${remaining/"$k"/}" ;;
		esac
		special_left="$(printf '%s' "$special_left" | tr -s ' ' | sed 's/^ //; s/ $//')"
	done
	stty "$old_stty" < /dev/tty
	printf '\n' > /dev/tty
	if [ -z "$remaining" ] && [ -z "$special_left" ]; then
		ok "$(T kb_ok)"
	else
		fail "$(T kb_fail): $remaining $special_left"
	fi
}

test_speakers() {
	out ""
	out "${C_BOLD}$(T spk_title)${C_RESET} $(T spk_intro)"
	afplay /System/Library/Sounds/Glass.aiff 2>/dev/null
	say "Testing speakers. One, two, three." 2>/dev/null
	manual_result "$(T spk_name)"
}

test_camera() {
	out ""
	out "${C_BOLD}$(T cam_title)${C_RESET} $(T cam_intro)"
	open -a "Photo Booth" 2>/dev/null || open -a "FaceTime" 2>/dev/null
	manual_result "$(T cam_name)"
}

test_display() {
	local page="$TMP_DIR/display-test.html"
	local msg="$(T disp_html)"
	cat > "$page" <<HTML
<!doctype html><html><head><meta charset="utf-8"><title>Display test</title>
<style>html,body{margin:0;height:100%;cursor:none;font:20px -apple-system,sans-serif}
#t{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;text-align:center;color:#888;background:#111;cursor:default}</style></head>
<body><div id="t">$msg</div>
<script>
var c=['#000','#fff','#f00','#0f0','#00f','#808080','linear-gradient(90deg,#000,#fff)'],i=-1,t=document.getElementById('t');
function next(){if(i<0){t.remove();document.documentElement.requestFullscreen&&document.documentElement.requestFullscreen();}
i=(i+1)%c.length;document.body.style.background=c[i];}
document.addEventListener('click',next);document.addEventListener('keydown',function(e){if(e.key===' ')next();});
</script></body></html>
HTML
	out ""
	out "${C_BOLD}$(T disp_title)${C_RESET} $(T disp_intro)"
	open "$page" 2>/dev/null
	manual_result "$(T disp_name)"
}

if [ "$INTERACTIVE" != "no" ] && has_tty; then
	if [ "$INTERACTIVE" = "yes" ] || { out ""; ask_yn "$(T ask_manual)"; }; then
		section "$(T s_manual)"
		test_keyboard
		test_speakers
		test_camera
		test_display
	fi
fi

