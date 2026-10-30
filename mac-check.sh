#!/bin/bash
#
# mac-check — перевірка стану MacBook перед купівлею вживаного.
#
# Запуск локально:   bash mac-check.sh [опції]
# Запуск з інтернету: bash <(curl -fsSL https://raw.githubusercontent.com/Meizuno/Mac-Checker/main/mac-check.sh)
#
# Скрипт нічого не змінює в системі: лише читає дані через system_profiler,
# ioreg, profiles, csrutil тощо. Сумісний зі штатним bash 3.2 у macOS.
#
# Тексти інтерфейсу — у каталогах catalog_<мова> наприкінці файлу.

LANGS="uk en de pl es fr it pt nl cs tr"

# Увесь код загорнутий у main(), щоб `curl ... | bash` спершу прочитав скрипт
# повністю, а вже потім почав його виконувати.
main() {

VERSION="1.2.0"

INTERACTIVE=""      # "", "yes" або "no"
REPORT_FILE=""
USE_COLOR=1
UI_LANG=""          # порожньо — визначити з мови системи
SHOW_HELP=0

while [ $# -gt 0 ]; do
	case "$1" in
		-i|--interactive) INTERACTIVE="yes" ;;
		-n|--no-interactive) INTERACTIVE="no" ;;
		-o|--output) shift; REPORT_FILE="$1" ;;
		-l|--lang) shift; UI_LANG="$1" ;;
		--lang=*) UI_LANG="${1#--lang=}" ;;
		--no-color) USE_COLOR=0 ;;
		-h|--help) SHOW_HELP=1 ;;
		-v|--version) echo "mac-check $VERSION"; return 0 ;;
		*) echo "Unknown option: $1 (see --help)" >&2; return 2 ;;
	esac
	shift
done

# ---------------------------------------------------------------- мова ----

if [ -z "$UI_LANG" ]; then
	UI_LANG="$(defaults read -g AppleLanguages 2>/dev/null | sed -n '2s/[^a-zA-Z]*\([a-zA-Z]*\).*/\1/p')"
	[ -z "$UI_LANG" ] && UI_LANG="${LC_ALL:-${LANG:-en}}"
	UI_LANG="$(printf '%s' "$UI_LANG" | cut -c1-2 | tr 'A-Z' 'a-z')"
	case " $LANGS " in *" $UI_LANG "*) ;; *) UI_LANG="en" ;; esac
else
	UI_LANG="$(printf '%s' "$UI_LANG" | tr 'A-Z' 'a-z')"
	[ "$UI_LANG" = ua ] && UI_LANG="uk"
	case " $LANGS " in
		*" $UI_LANG "*) ;;
		*) echo "Unsupported language: $UI_LANG (available: $LANGS)" >&2; return 2 ;;
	esac
fi

# Англійська завантажується першою: якщо в перекладі бракує ключа, лишиться англійський текст.
load_catalog() {
	local key text
	while IFS='=' read -r key text; do
		case "$key" in ""|\#*) continue ;; esac
		printf -v "T_$key" '%s' "$text"
	done
}
load_catalog < <(catalog_en)
[ "$UI_LANG" != en ] && load_catalog < <("catalog_$UI_LANG")

# Текст повідомлення за ключем; решта аргументів підставляється замість %s.
T() {
	local var="T_$1"
	shift
	printf "${!var}" "$@"
}

usage() {
	echo "mac-check $VERSION — $(T help_title)"
	echo
	T help_usage; echo
	echo
	printf '  %-26s %s\n' "-l, --lang CODE" "$(T help_lang): $LANGS"
	printf '  %-26s %s\n' "-i, --interactive" "$(T help_i)"
	printf '  %-26s %s\n' "-n, --no-interactive" "$(T help_n)"
	printf '  %-26s %s\n' "-o, --output FILE" "$(T help_o)"
	printf '  %-26s %s\n' "    --no-color" "$(T help_color)"
	printf '  %-26s %s\n' "-h, --help" "$(T help_h)"
	printf '  %-26s %s\n' "-v, --version" "$(T help_v)"
	echo
	T help_sudo; echo
}

if [ "$SHOW_HELP" = 1 ]; then usage; return 0; fi

if [ "$(uname -s)" != "Darwin" ]; then
	T err_macos >&2; echo >&2
	return 1
fi

# ---------------------------------------------------------------- вивід ----

if [ "$USE_COLOR" = 1 ] && [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
	C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_BLUE=$'\033[34m'; C_CYAN=$'\033[36m'
else
	C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BLUE=""; C_CYAN=""
fi

if [ -n "$REPORT_FILE" ]; then
	: > "$REPORT_FILE" || return 1
fi

# Друкує рядок у термінал і (без кольорів) у файл звіту.
out() {
	printf '%s\n' "$1"
	if [ -n "$REPORT_FILE" ]; then
		printf '%s\n' "$1" | sed $'s/\033\\[[0-9;]*m//g' >> "$REPORT_FILE"
	fi
}

N_OK=0; N_WARN=0; N_FAIL=0
ISSUES=""   # рядки "WARN|текст" або "FAIL|текст"

section() { out ""; out "${C_BOLD}${C_BLUE}━━ $1 ${C_RESET}"; }
ok()      { N_OK=$((N_OK + 1));     out "  ${C_GREEN}✔${C_RESET} $1"; }
warn()    { N_WARN=$((N_WARN + 1)); out "  ${C_YELLOW}▲${C_RESET} $1"; ISSUES="${ISSUES}WARN|$1"$'\n'; }
fail()    { N_FAIL=$((N_FAIL + 1)); out "  ${C_RED}✖${C_RESET} $1"; ISSUES="${ISSUES}FAIL|$1"$'\n'; }
info()    { out "  ${C_DIM}•${C_RESET} $1"; }
hint()    { out "    ${C_DIM}$1${C_RESET}"; }

# Питання з відповіддю y/n. Читає з /dev/tty, бо stdin може бути трубою curl.
# «Так» різними мовами: y(es), т(ак), j(a), t(ak), s(í/im), o(ui), a(no), e(vet).
ask_yn() {
	local reply
	printf '%s [y/n] ' "$1" > /dev/tty
	IFS= read -r reply < /dev/tty || return 1
	case "$reply" in [yYтТjJtTsSoOaAeE]*) return 0 ;; *) return 1 ;; esac
}

has_tty() { [ -r /dev/tty ] && [ -w /dev/tty ] && : < /dev/tty 2>/dev/null; }

TMP_DIR="$(mktemp -d -t mac-check)" || return 1
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------- збір даних ----

[ -t 2 ] && printf '%s' "${C_DIM}$(T collecting)${C_RESET}" >&2

system_profiler -json \
	SPHardwareDataType SPSoftwareDataType SPPowerDataType SPNVMeDataType \
	SPSerialATADataType SPDisplaysDataType SPCameraDataType SPAudioDataType \
	SPBluetoothDataType SPiBridgeDataType \
	> "$TMP_DIR/sp.json" 2>/dev/null

# Розбір JSON через JavaScript for Automation (є в кожній macOS, на відміну від jq/python).
# Результат — рядки "ключ<TAB>значення".
osascript -l JavaScript - "$TMP_DIR/sp.json" > "$TMP_DIR/sp.tsv" 2>/dev/null <<'JS'
ObjC.import('Foundation');
function run(argv) {
	var raw = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
	var d = {};
	try { d = JSON.parse(raw.js); } catch (e) {}
	var out = [];
	function put(k, v) {
		if (v === undefined || v === null || v === '') return;
		out.push(k + '\t' + String(v).replace(/[\t\r\n]+/g, ' '));
	}
	function find(o, key) {
		if (o === null || typeof o !== 'object') return undefined;
		if (Array.isArray(o)) {
			for (var i = 0; i < o.length; i++) { var r = find(o[i], key); if (r !== undefined) return r; }
			return undefined;
		}
		if (key in o) return o[key];
		for (var k in o) { var r2 = find(o[k], key); if (r2 !== undefined) return r2; }
		return undefined;
	}
	function first(name) { return (d[name] || [])[0] || {}; }

	var hw = first('SPHardwareDataType');
	put('model_name', hw.machine_name);
	put('model_id', hw.machine_model);
	put('model_number', hw.model_number);
	put('serial', hw.serial_number);
	put('chip', hw.chip_type || hw.cpu_type);
	put('cpu_speed', hw.current_processor_speed);
	put('cores', hw.number_processors);
	put('memory', hw.physical_memory);
	put('activation_lock', hw.activation_lock_status);

	var sw = first('SPSoftwareDataType');
	put('os', sw.os_version);

	var pw = d.SPPowerDataType || [];
	put('bat_present', find(pw, 'sppower_battery_health_info') !== undefined ? 'yes' : '');
	put('bat_cycles', find(pw, 'sppower_battery_cycle_count'));
	put('bat_health', find(pw, 'sppower_battery_health'));
	put('bat_maxcap', find(pw, 'sppower_battery_health_maximum_capacity'));
	put('bat_charge', find(pw, 'sppower_battery_state_of_charge'));
	put('bat_charging', find(pw, 'sppower_battery_is_charging'));
	put('bat_serial', find(pw, 'sppower_battery_serial_number'));
	put('ac_connected', find(pw, 'sppower_battery_charger_connected'));
	put('ac_watts', find(pw, 'sppower_ac_charger_watts'));
	put('ac_name', find(pw, 'sppower_ac_charger_name'));

	var n = 0;
	['SPNVMeDataType', 'SPSerialATADataType'].forEach(function (t) {
		(d[t] || []).forEach(function (ctrl) {
			(ctrl._items || []).forEach(function (dr) {
				if (dr.detachable_drive === 'yes' || dr.removable_media === 'yes') return;
				n++;
				put('disk_' + n, [dr.device_model || dr._name, dr.size || '', dr.smart_status || '', dr.medium_type || (t === 'SPNVMeDataType' ? 'ssd' : '')].join('|'));
			});
		});
	});
	put('disk_count', n);

	var g = 0, s = 0;
	(d.SPDisplaysDataType || []).forEach(function (gpu) {
		g++;
		put('gpu_' + g, [gpu.sppci_model || gpu._name, gpu.sppci_cores || '', gpu.spdisplays_vram || gpu.spdisplays_vram_shared || ''].join('|'));
		(gpu.spdisplays_ndrvs || []).forEach(function (sc) {
			s++;
			var internal = sc.spdisplays_connection_type === 'spdisplays_internal' || /built-?in|color lcd/i.test(sc._name || '');
			put('disp_' + s, [sc._name, sc._spdisplays_pixels || sc._spdisplays_resolution || '', internal ? '1' : '0'].join('|'));
		});
	});
	put('gpu_count', g);
	put('disp_count', s);

	put('cameras', (d.SPCameraDataType || []).map(function (c) { return c._name; }).join('; '));

	var spk = [], mic = [];
	(d.SPAudioDataType || []).forEach(function (grp) {
		(grp._items || []).forEach(function (a) {
			if (a.coreaudio_device_transport !== 'coreaudio_device_type_builtin') return;
			if (a.coreaudio_device_output) spk.push(a._name);
			if (a.coreaudio_device_input) mic.push(a._name);
		});
	});
	put('speakers', spk.join('; '));
	put('mics', mic.join('; '));

	var bt = d.SPBluetoothDataType || [];
	put('bt_chip', find(bt, 'controller_chipset'));
	put('bt_state', find(bt, 'controller_state'));

	put('t2', find(d.SPiBridgeDataType || [], 'ibridge_model_name'));
	return out.join('\n');
}
JS

while IFS=$'\t' read -r key val; do
	[ -n "$key" ] && printf -v "SP_$key" '%s' "$val"
done < "$TMP_DIR/sp.tsv"

# Значення поля з `ioreg` для батареї (числа або Yes/No).
ioreg -rn AppleSmartBattery > "$TMP_DIR/battery.txt" 2>/dev/null
bat_field() {
	LC_ALL=C sed -n "s/^ *\"$1\" = \\(.*\\)$/\\1/p" "$TMP_DIR/battery.txt" | head -1
}

[ -t 2 ] && printf '\r\033[K' >&2

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
}

# ============================================================ каталоги ====
#
# Формат: ключ=текст. %s — місце для значення. Щоб додати мову, скопіюйте
# catalog_en як catalog_<код>, перекладіть тексти й допишіть код у LANGS.

catalog_en() { cat <<'EOF'
collecting=Collecting system data (10–30 s)…
title=Mac health check
s_system=System
model=Model
serial=Serial number
cpu=Processor
sec_chip=Security chip
memory=Memory
unknown=unknown
uptime=Uptime: %sd %sh %sm
not_laptop=This is not a MacBook (%s) — laptop-specific checks will be skipped
s_locks=Locks and enrollment (most important!)
al_off=Activation Lock is off
al_on=Activation Lock is ON — this Mac is tied to an Apple ID
al_on_hint1=The seller must sign out of their Apple ID and turn off Find My Mac in front of you.
al_on_hint2=Otherwise, after reinstalling macOS the Mac will ask for someone else's password.
fmm_on=Find My Mac is on (FMM token found in NVRAM)
al_na=Activation Lock: status unavailable (Mac without T2/Apple Silicon)
mdm_na=MDM: could not get the status
dep_yes=Mac is enrolled in a corporate DEP/ABM — the company can lock it
dep_no=Not enrolled in DEP / Apple Business Manager
mdm_yes=Mac is managed by MDM (%s) — a corporate device
mdm_no=Not managed by MDM
profiles_yes=Configuration profiles installed: %s (see Settings → Profiles)
profiles_no=No configuration profiles
fw_yes=Firmware (EFI) password is set — you can't boot from another disk without it
fw_no=No firmware password
icloud_yes=Current user is signed in to iCloud (%s) — must sign out before the sale
icloud_check=iCloud sign-in: check the top of System Settings (Activation Lock above is what matters)
sip_on=System Integrity Protection (SIP) is on
sip_off=SIP is off or customized — the system has been modified
fv_on=FileVault is on (fine, but the seller must erase the Mac before handing it over)
fv_off=FileVault is off
s_battery=Battery and power
bat_missing=Battery not detected — it may be disconnected or faulty
cycles=Charge cycles: %s of %s
cycles_over=rated lifespan exceeded
cycles_worn=battery is fairly worn
maxcap=Maximum capacity
mah=%s of %s mAh
replace=Apple recommends replacement
bat_cond=Battery condition (macOS)
bat_fake=Very few cycles with reduced capacity — the battery may be a non-genuine replacement
charge_now=Current charge
bat_serial=Battery serial number
ac_on=Charger connected
watt=W
charging=Battery is charging
ac_off=Charger not connected — plug it in to verify charging
no_battery=No battery (desktop Mac)
s_storage=Storage
disk_none=Could not detect the internal drive
smart_failing=the drive is about to fail!
smart_na=SMART unavailable
ssd_wear=SSD wear
ssd_written=Total data written to SSD
smart_sudo=smartctl returned no wear data — run the script with sudo.
smart_nodata=smartctl returned no wear data for this drive.
smart_install=To check SSD wear, install smartmontools (brew install smartmontools) and run again.
sys_volume=System volume: %s free of %s
s_hw=Display, camera, audio, wireless
graphics=Graphics
cores=cores
disp_int=Built-in display
disp_ext=External display
disp_none=Built-in display not detected (lid closed? or a faulty display cable)
camera=Camera
camera_none=Camera not detected
speakers=Speakers
speakers_none=Built-in speakers not detected
mic=Microphone
mic_none=Built-in microphone not detected
wifi_ok=Wi-Fi module present
wifi_none=Wi-Fi module not detected
bt_on=on
bt_none=Bluetooth controller not detected
s_stability=Stability
panics_none=No kernel panics in the logs
panics=Kernel panics: %s, latest %s
panics_hw=possible hardware problem
panics_hint=Logs may have been cleared, so no panics does not guarantee stability.
therm_yes=Thermal throttling recorded
therm_no=No thermal throttling recorded
works_q=%s — working correctly?
checked_ok=checked manually
checked_fail=problem found during manual check
kb_title=Keyboard test.
kb_intro=Switch to the English (US) layout and press every key.
kb_hint=Esc to finish. Check modifier keys (⌘ ⌥ ⌃ ⇧ fn) separately in any app.
kb_left=Remaining
kb_ok=Keyboard: all tested keys work
kb_fail=Keyboard: not pressed / not working
spk_title=Speaker test.
spk_intro=A chime and a voice will play. Turn the volume all the way up and listen for crackling.
spk_name=Speakers
cam_title=Camera and microphone test.
cam_intro=Opening Photo Booth: record a short video and play it back.
cam_name=Camera and microphone
disp_title=Display test.
disp_intro=Opening a page with solid colors in the browser.
disp_name=Display (no dead pixels or backlight bleed)
disp_html=Click to go full screen.<br>Then click or press Space for the next color. Look for dead pixels, stains and backlight bleed.<br>Esc to exit.
ask_manual=Run the manual tests (keyboard, speakers, camera, display)?
s_manual=Manual tests
s_summary=Summary
verdict_fail=Serious problems found. Don't buy until they are fixed or the price is lowered.
verdict_warn=No critical problems, but review the warnings.
verdict_ok=All automatic checks passed.
s_manual_check=Also check by hand
chk_warranty=Warranty and purchase date
serial_lower=serial number
chk_serial=The serial number in the system matches the one printed on the bottom case
chk_diag=Apple Diagnostics: shut down, then hold the power button (Apple Silicon) or D (Intel) while starting up
chk_case=Case: dents, signs of opened screws, lid alignment, hinge play
chk_liquid=Liquid damage: stains on the screen, sticky keys, corroded ports
chk_ports=All USB-C/Thunderbolt/HDMI/MagSafe/audio ports: charging and data transfer
chk_trackpad=Trackpad: click across the whole surface, Force Touch, gestures; Touch ID; keyboard backlight
chk_seller=The seller must sign out of Apple ID, turn off Find My Mac and erase the Mac in front of you
chk_erase=(Settings → General → Transfer or Reset → Erase All Content and Settings)
chk_sudo=Running with sudo adds configuration profile and firmware password (Intel) checks.
report_saved=Report saved
err_macos=This script only works on macOS.
help_title=health check for a used MacBook
help_usage=Usage: mac-check.sh [options]
help_lang=interface language (default: system language)
help_i=run the manual tests right away (keyboard, sound, camera, display)
help_n=do not offer the manual tests
help_o=save the report to a text file
help_color=disable colors
help_h=show this help
help_v=show version
help_sudo=Running with sudo adds firmware password (Intel) and configuration profile checks, and lets smartctl read SSD wear.
EOF
}

catalog_uk() { cat <<'EOF'
collecting=Збираю дані про систему (10–30 с)…
title=перевірка стану Mac
s_system=Система
model=Модель
serial=Серійний номер
cpu=Процесор
sec_chip=Чип безпеки
memory=Оперативна пам'ять
unknown=невідомо
uptime=Час роботи з останнього запуску: %s д %s год %s хв
not_laptop=Це не MacBook (%s) — частина перевірок для ноутбука буде пропущена
s_locks=Блокування та прив'язки (найважливіше!)
al_off=Activation Lock вимкнено
al_on=Activation Lock УВІМКНЕНО — Mac прив'язаний до Apple ID
al_on_hint1=Продавець має вийти з Apple ID і вимкнути «Знайти Mac» при вас.
al_on_hint2=Інакше після перевстановлення macOS Mac попросить чужий пароль.
fmm_on=Увімкнено «Знайти Mac» (є токен FMM у NVRAM)
al_na=Activation Lock: статус недоступний (Mac без T2/Apple Silicon)
mdm_na=MDM: не вдалося отримати статус
dep_yes=Mac зареєстровано в корпоративному DEP/ABM — його може заблокувати компанія
dep_no=Не прив'язаний до DEP / Apple Business Manager
mdm_yes=Mac під керуванням MDM (%s) — корпоративний пристрій
mdm_no=Не під керуванням MDM
profiles_yes=Встановлено профілів конфігурації: %s (див. Налаштування → Профілі)
profiles_no=Профілів конфігурації немає
fw_yes=Встановлено пароль прошивки (EFI) — без нього не завантажитись з іншого диска
fw_no=Пароль прошивки не встановлено
icloud_yes=Поточний користувач увійшов в iCloud (%s) — перед продажем треба вийти
icloud_check=Вхід в iCloud: перевірте вгорі Системних налаштувань (головне — Activation Lock вище)
sip_on=Захист цілісності системи (SIP) увімкнено
sip_off=SIP вимкнено або змінено — систему модифікували
fv_on=FileVault увімкнено (нормально, але продавець має стерти Mac перед передачею)
fv_off=FileVault вимкнено
s_battery=Батарея та живлення
bat_missing=Батарею не виявлено — можливо, вона відключена або несправна
cycles=Цикли заряду: %s з %s
cycles_over=ресурс вичерпано
cycles_worn=батарея досить зношена
maxcap=Максимальна ємність
mah=%s з %s мА·год
replace=Apple рекомендує заміну
bat_cond=Стан батареї за macOS
bat_fake=Дуже мало циклів при зниженій ємності — можливо, батарею замінено на неоригінальну
charge_now=Поточний заряд
bat_serial=Серійний номер батареї
ac_on=Зарядний пристрій підключено
watt=Вт
charging=Батарея заряджається
ac_off=Зарядний пристрій не підключено — підключіть, щоб перевірити заряджання
no_battery=Батарея відсутня (стаціонарний Mac)
s_storage=Накопичувач
disk_none=Не вдалося визначити внутрішній накопичувач
smart_failing=диск скоро вийде з ладу!
smart_na=SMART недоступний
ssd_wear=Знос SSD
ssd_written=Записано на SSD за весь час
smart_sudo=smartctl не повернув даних про знос — запустіть скрипт через sudo.
smart_nodata=smartctl не повернув даних про знос для цього накопичувача.
smart_install=Для перевірки зносу SSD встановіть smartmontools (brew install smartmontools) і запустіть знову.
sys_volume=Системний том: %s вільно з %s
s_hw=Екран, камера, звук, бездротові модулі
graphics=Графіка
cores=ядер
disp_int=Вбудований дисплей
disp_ext=Зовнішній дисплей
disp_none=Вбудований дисплей не виявлено (кришка закрита? або несправний шлейф)
camera=Камера
camera_none=Камеру не виявлено
speakers=Динаміки
speakers_none=Вбудовані динаміки не виявлено
mic=Мікрофон
mic_none=Вбудований мікрофон не виявлено
wifi_ok=Wi-Fi модуль присутній
wifi_none=Wi-Fi модуль не виявлено
bt_on=увімкнено
bt_none=Bluetooth-контролер не виявлено
s_stability=Стабільність
panics_none=Збоїв ядра (kernel panic) у журналах немає
panics=Збоїв ядра (kernel panic): %s, останній %s
panics_hw=можлива апаратна проблема
panics_hint=Журнали могли очистити, тож відсутність збоїв не гарантує стабільності.
therm_yes=Зафіксовано тротлінг через перегрів
therm_no=Тротлінгу через перегрів не зафіксовано
works_q=%s — усе гаразд?
checked_ok=перевірено вручну
checked_fail=проблема під час ручної перевірки
kb_title=Тест клавіатури.
kb_intro=Перемкніть розкладку на англійську й натисніть кожну клавішу.
kb_hint=Esc — завершити. Клавіші-модифікатори (⌘ ⌥ ⌃ ⇧ fn) перевірте окремо в будь-якій програмі.
kb_left=Залишилось
kb_ok=Клавіатура: усі перевірені клавіші спрацювали
kb_fail=Клавіатура: не натиснуто/не працює
spk_title=Тест динаміків.
spk_intro=Зараз прозвучить сигнал і голос. Гучність — на максимум, слухайте хрипіння.
spk_name=Динаміки
cam_title=Тест камери й мікрофона.
cam_intro=Відкриваю Photo Booth: запишіть коротке відео і перегляньте його.
cam_name=Камера та мікрофон
disp_title=Тест екрана.
disp_intro=Відкриваю сторінку з однотонними кольорами в браузері.
disp_name=Екран (без битих пікселів і засвітів)
disp_html=Натисніть, щоб розгорнути на весь екран.<br>Далі клік або пробіл — наступний колір. Шукайте биті пікселі, плями, засвіти.<br>Esc — вийти.
ask_manual=Запустити ручні тести (клавіатура, динаміки, камера, екран)?
s_manual=Ручні тести
s_summary=Підсумок
verdict_fail=Є серйозні проблеми. Не купуйте, доки їх не усунуть або не знизять ціну.
verdict_warn=Критичних проблем немає, але зверніть увагу на попередження.
verdict_ok=Автоматичні перевірки пройдено успішно.
s_manual_check=Перевірте також вручну
chk_warranty=Гарантія та дата покупки
serial_lower=серійний номер
chk_serial=Серійний номер у системі збігається з написаним на днищі корпусу
chk_diag=Apple Diagnostics: вимкніть Mac, затисніть кнопку живлення (Apple Silicon) або D (Intel) під час увімкнення
chk_case=Корпус: вм'ятини, сліди розкриття гвинтів, рівність кришки, люфт шарніра
chk_liquid=Сліди рідини: плями на екрані, липкі клавіші, окиснення портів
chk_ports=Усі порти USB-C/Thunderbolt/HDMI/MagSafe/аудіо: заряджання й передача даних
chk_trackpad=Трекпад: клік по всій площі, Force Touch, жести; Touch ID; підсвітка клавіатури
chk_seller=Продавець має при вас вийти з Apple ID, вимкнути «Знайти Mac» і стерти Mac
chk_erase=(Налаштування → Загальні → Перенесення або скидання → Стерти весь вміст і налаштування)
chk_sudo=Запуск через sudo додасть перевірку профілів конфігурації та пароля прошивки (Intel).
report_saved=Звіт збережено
err_macos=Цей скрипт працює лише на macOS.
help_title=перевірка стану вживаного MacBook
help_usage=Використання: mac-check.sh [опції]
help_lang=мова інтерфейсу (типово — мова системи)
help_i=одразу запустити ручні тести (клавіатура, звук, камера, екран)
help_n=не пропонувати ручні тести
help_o=зберегти звіт у текстовий файл
help_color=без кольорів
help_h=ця довідка
help_v=версія
help_sudo=Запуск через sudo додає перевірку пароля прошивки (Intel), списку профілів і дозволяє smartctl прочитати знос SSD.
EOF
}

catalog_de() { cat <<'EOF'
collecting=Systemdaten werden gesammelt (10–30 s)…
title=Mac-Zustandsprüfung
s_system=System
model=Modell
serial=Seriennummer
cpu=Prozessor
sec_chip=Sicherheitschip
memory=Arbeitsspeicher
unknown=unbekannt
uptime=Laufzeit seit dem letzten Start: %s T %s Std. %s Min.
not_laptop=Dies ist kein MacBook (%s) — Laptop-spezifische Prüfungen werden übersprungen
s_locks=Sperren und Registrierung (am wichtigsten!)
al_off=Aktivierungssperre ist aus
al_on=Aktivierungssperre ist AN — dieser Mac ist an eine Apple-ID gebunden
al_on_hint1=Der Verkäufer muss sich vor Ihnen von der Apple-ID abmelden und „Meinen Mac suchen“ deaktivieren.
al_on_hint2=Sonst verlangt der Mac nach einer Neuinstallation von macOS ein fremdes Passwort.
fmm_on=„Meinen Mac suchen“ ist aktiv (FMM-Token im NVRAM gefunden)
al_na=Aktivierungssperre: Status nicht verfügbar (Mac ohne T2/Apple Silicon)
mdm_na=MDM: Status konnte nicht ermittelt werden
dep_yes=Mac ist in einem Firmen-DEP/ABM registriert — die Firma kann ihn sperren
dep_no=Nicht in DEP / Apple Business Manager registriert
mdm_yes=Mac wird per MDM verwaltet (%s) — ein Firmengerät
mdm_no=Nicht per MDM verwaltet
profiles_yes=Installierte Konfigurationsprofile: %s (siehe Einstellungen → Profile)
profiles_no=Keine Konfigurationsprofile
fw_yes=Firmware-Passwort (EFI) ist gesetzt — ohne es kein Start von einem anderen Laufwerk
fw_no=Kein Firmware-Passwort
icloud_yes=Der aktuelle Benutzer ist bei iCloud angemeldet (%s) — vor dem Verkauf abmelden
icloud_check=iCloud-Anmeldung: oben in den Systemeinstellungen prüfen (entscheidend ist die Aktivierungssperre oben)
sip_on=Systemintegritätsschutz (SIP) ist aktiv
sip_off=SIP ist deaktiviert oder angepasst — das System wurde verändert
fv_on=FileVault ist an (in Ordnung, aber der Verkäufer muss den Mac vor der Übergabe löschen)
fv_off=FileVault ist aus
s_battery=Batterie und Stromversorgung
bat_missing=Batterie nicht erkannt — evtl. abgeklemmt oder defekt
cycles=Ladezyklen: %s von %s
cycles_over=Lebensdauer überschritten
cycles_worn=Batterie ist recht verschlissen
maxcap=Maximale Kapazität
mah=%s von %s mAh
replace=Apple empfiehlt einen Austausch
bat_cond=Batteriezustand laut macOS
bat_fake=Sehr wenige Zyklen bei reduzierter Kapazität — möglicherweise ein nicht originaler Ersatzakku
charge_now=Aktueller Ladestand
bat_serial=Seriennummer der Batterie
ac_on=Netzteil angeschlossen
watt=W
charging=Batterie wird geladen
ac_off=Netzteil nicht angeschlossen — anschließen, um das Laden zu prüfen
no_battery=Keine Batterie (Desktop-Mac)
s_storage=Speicher
disk_none=Internes Laufwerk konnte nicht erkannt werden
smart_failing=das Laufwerk fällt bald aus!
smart_na=SMART nicht verfügbar
ssd_wear=SSD-Verschleiß
ssd_written=Insgesamt auf die SSD geschrieben
smart_sudo=smartctl lieferte keine Verschleißdaten — Skript mit sudo ausführen.
smart_nodata=smartctl lieferte keine Verschleißdaten für dieses Laufwerk.
smart_install=Für den SSD-Verschleiß smartmontools installieren (brew install smartmontools) und erneut ausführen.
sys_volume=Systemvolume: %s frei von %s
s_hw=Display, Kamera, Audio, Funk
graphics=Grafik
cores=Kerne
disp_int=Integriertes Display
disp_ext=Externes Display
disp_none=Integriertes Display nicht erkannt (Deckel zu? oder defektes Displaykabel)
camera=Kamera
camera_none=Kamera nicht erkannt
speakers=Lautsprecher
speakers_none=Integrierte Lautsprecher nicht erkannt
mic=Mikrofon
mic_none=Integriertes Mikrofon nicht erkannt
wifi_ok=WLAN-Modul vorhanden
wifi_none=WLAN-Modul nicht erkannt
bt_on=an
bt_none=Bluetooth-Controller nicht erkannt
s_stability=Stabilität
panics_none=Keine Kernel-Panics in den Protokollen
panics=Kernel-Panics: %s, zuletzt %s
panics_hw=mögliches Hardwareproblem
panics_hint=Protokolle können gelöscht worden sein — keine Panics garantieren keine Stabilität.
therm_yes=Thermische Drosselung festgestellt
therm_no=Keine thermische Drosselung festgestellt
works_q=%s — funktioniert einwandfrei?
checked_ok=manuell geprüft
checked_fail=Problem bei der manuellen Prüfung
kb_title=Tastaturtest.
kb_intro=Auf das Layout Englisch (US) umstellen und jede Taste drücken.
kb_hint=Esc zum Beenden. Sondertasten (⌘ ⌥ ⌃ ⇧ fn) separat in einer beliebigen App prüfen.
kb_left=Verbleibend
kb_ok=Tastatur: alle getesteten Tasten funktionieren
kb_fail=Tastatur: nicht gedrückt / funktioniert nicht
spk_title=Lautsprechertest.
spk_intro=Es ertönen ein Signal und eine Stimme. Lautstärke voll aufdrehen und auf Knistern achten.
spk_name=Lautsprecher
cam_title=Kamera- und Mikrofontest.
cam_intro=Photo Booth wird geöffnet: ein kurzes Video aufnehmen und abspielen.
cam_name=Kamera und Mikrofon
disp_title=Displaytest.
disp_intro=Eine Seite mit Vollfarben wird im Browser geöffnet.
disp_name=Display (ohne Pixelfehler und Lichthöfe)
disp_html=Klicken für Vollbild.<br>Dann Klick oder Leertaste für die nächste Farbe. Auf Pixelfehler, Flecken und Lichthöfe achten.<br>Esc zum Beenden.
ask_manual=Manuelle Tests ausführen (Tastatur, Lautsprecher, Kamera, Display)?
s_manual=Manuelle Tests
s_summary=Zusammenfassung
verdict_fail=Ernste Probleme gefunden. Nicht kaufen, bis sie behoben sind oder der Preis gesenkt wird.
verdict_warn=Keine kritischen Probleme, aber die Warnungen beachten.
verdict_ok=Alle automatischen Prüfungen bestanden.
s_manual_check=Zusätzlich von Hand prüfen
chk_warranty=Garantie und Kaufdatum
serial_lower=Seriennummer
chk_serial=Die Seriennummer im System stimmt mit der auf der Gehäuseunterseite überein
chk_diag=Apple Diagnose: ausschalten, dann beim Start den Ein-/Ausschalter (Apple Silicon) oder D (Intel) gedrückt halten
chk_case=Gehäuse: Dellen, Spuren geöffneter Schrauben, Deckelausrichtung, Scharnierspiel
chk_liquid=Flüssigkeitsschaden: Flecken auf dem Display, klebrige Tasten, korrodierte Anschlüsse
chk_ports=Alle Anschlüsse USB-C/Thunderbolt/HDMI/MagSafe/Audio: Laden und Datenübertragung
chk_trackpad=Trackpad: Klick auf der ganzen Fläche, Force Touch, Gesten; Touch ID; Tastaturbeleuchtung
chk_seller=Der Verkäufer muss sich vor Ihnen von der Apple-ID abmelden, „Meinen Mac suchen“ deaktivieren und den Mac löschen
chk_erase=(Einstellungen → Allgemein → Übertragen oder zurücksetzen → Alle Inhalte & Einstellungen löschen)
chk_sudo=Mit sudo werden zusätzlich Konfigurationsprofile und das Firmware-Passwort (Intel) geprüft.
report_saved=Bericht gespeichert
err_macos=Dieses Skript läuft nur unter macOS.
help_title=Zustandsprüfung für ein gebrauchtes MacBook
help_usage=Verwendung: mac-check.sh [Optionen]
help_lang=Sprache der Oberfläche (Standard: Systemsprache)
help_i=manuelle Tests sofort starten (Tastatur, Ton, Kamera, Display)
help_n=keine manuellen Tests anbieten
help_o=Bericht in eine Textdatei speichern
help_color=ohne Farben
help_h=diese Hilfe
help_v=Version
help_sudo=Mit sudo: zusätzlich Firmware-Passwort (Intel) und Konfigurationsprofile, außerdem kann smartctl den SSD-Verschleiß lesen.
EOF
}

catalog_pl() { cat <<'EOF'
collecting=Zbieranie danych o systemie (10–30 s)…
title=sprawdzenie stanu Maca
s_system=System
model=Model
serial=Numer seryjny
cpu=Procesor
sec_chip=Układ zabezpieczeń
memory=Pamięć RAM
unknown=nieznane
uptime=Czas działania od ostatniego uruchomienia: %s d %s godz. %s min
not_laptop=To nie jest MacBook (%s) — testy dla laptopa zostaną pominięte
s_locks=Blokady i rejestracje (najważniejsze!)
al_off=Blokada aktywacji jest wyłączona
al_on=Blokada aktywacji jest WŁĄCZONA — ten Mac jest przypisany do Apple ID
al_on_hint1=Sprzedawca musi przy Tobie wylogować się z Apple ID i wyłączyć „Znajdź mój Mac”.
al_on_hint2=W przeciwnym razie po ponownej instalacji macOS Mac poprosi o cudze hasło.
fmm_on=Włączone „Znajdź mój Mac” (token FMM w NVRAM)
al_na=Blokada aktywacji: status niedostępny (Mac bez T2/Apple Silicon)
mdm_na=MDM: nie udało się pobrać statusu
dep_yes=Mac jest zarejestrowany w firmowym DEP/ABM — firma może go zablokować
dep_no=Nie jest zarejestrowany w DEP / Apple Business Manager
mdm_yes=Mac jest zarządzany przez MDM (%s) — urządzenie firmowe
mdm_no=Nie jest zarządzany przez MDM
profiles_yes=Zainstalowane profile konfiguracyjne: %s (zob. Ustawienia → Profile)
profiles_no=Brak profili konfiguracyjnych
fw_yes=Ustawione hasło oprogramowania sprzętowego (EFI) — bez niego nie uruchomisz Maca z innego dysku
fw_no=Brak hasła oprogramowania sprzętowego
icloud_yes=Bieżący użytkownik jest zalogowany do iCloud (%s) — przed sprzedażą trzeba się wylogować
icloud_check=Logowanie do iCloud: sprawdź na górze Ustawień systemowych (najważniejsza jest blokada aktywacji powyżej)
sip_on=Ochrona integralności systemu (SIP) jest włączona
sip_off=SIP jest wyłączona lub zmieniona — system był modyfikowany
fv_on=FileVault jest włączony (w porządku, ale sprzedawca musi wymazać Maca przed przekazaniem)
fv_off=FileVault jest wyłączony
s_battery=Bateria i zasilanie
bat_missing=Nie wykryto baterii — może być odłączona lub uszkodzona
cycles=Cykle ładowania: %s z %s
cycles_over=przekroczona żywotność
cycles_worn=bateria jest dość zużyta
maxcap=Maksymalna pojemność
mah=%s z %s mAh
replace=Apple zaleca wymianę
bat_cond=Stan baterii wg macOS
bat_fake=Bardzo mało cykli przy obniżonej pojemności — bateria mogła zostać wymieniona na nieoryginalną
charge_now=Bieżący poziom naładowania
bat_serial=Numer seryjny baterii
ac_on=Zasilacz podłączony
watt=W
charging=Bateria się ładuje
ac_off=Zasilacz niepodłączony — podłącz go, aby sprawdzić ładowanie
no_battery=Brak baterii (Mac stacjonarny)
s_storage=Dysk
disk_none=Nie udało się wykryć dysku wewnętrznego
smart_failing=dysk wkrótce ulegnie awarii!
smart_na=SMART niedostępny
ssd_wear=Zużycie SSD
ssd_written=Łącznie zapisano na SSD
smart_sudo=smartctl nie zwrócił danych o zużyciu — uruchom skrypt przez sudo.
smart_nodata=smartctl nie zwrócił danych o zużyciu tego dysku.
smart_install=Aby sprawdzić zużycie SSD, zainstaluj smartmontools (brew install smartmontools) i uruchom ponownie.
sys_volume=Wolumin systemowy: wolne %s z %s
s_hw=Ekran, kamera, dźwięk, łączność bezprzewodowa
graphics=Grafika
cores=rdzeni
disp_int=Wbudowany ekran
disp_ext=Zewnętrzny ekran
disp_none=Nie wykryto wbudowanego ekranu (zamknięta pokrywa? lub uszkodzona taśma)
camera=Kamera
camera_none=Nie wykryto kamery
speakers=Głośniki
speakers_none=Nie wykryto wbudowanych głośników
mic=Mikrofon
mic_none=Nie wykryto wbudowanego mikrofonu
wifi_ok=Moduł Wi-Fi obecny
wifi_none=Nie wykryto modułu Wi-Fi
bt_on=włączony
bt_none=Nie wykryto kontrolera Bluetooth
s_stability=Stabilność
panics_none=Brak awarii jądra (kernel panic) w dziennikach
panics=Awarie jądra (kernel panic): %s, ostatnia %s
panics_hw=możliwy problem sprzętowy
panics_hint=Dzienniki mogły zostać wyczyszczone, więc brak awarii nie gwarantuje stabilności.
therm_yes=Wykryto dławienie termiczne
therm_no=Nie wykryto dławienia termicznego
works_q=%s — działa poprawnie?
checked_ok=sprawdzono ręcznie
checked_fail=problem podczas ręcznego sprawdzenia
kb_title=Test klawiatury.
kb_intro=Przełącz układ na angielski (US) i naciśnij każdy klawisz.
kb_hint=Esc — zakończ. Klawisze modyfikujące (⌘ ⌥ ⌃ ⇧ fn) sprawdź osobno w dowolnej aplikacji.
kb_left=Pozostało
kb_ok=Klawiatura: wszystkie sprawdzone klawisze działają
kb_fail=Klawiatura: nie naciśnięto / nie działa
spk_title=Test głośników.
spk_intro=Zabrzmi sygnał i głos. Ustaw maksymalną głośność i posłuchaj, czy nie trzeszczy.
spk_name=Głośniki
cam_title=Test kamery i mikrofonu.
cam_intro=Otwieram Photo Booth: nagraj krótki film i odtwórz go.
cam_name=Kamera i mikrofon
disp_title=Test ekranu.
disp_intro=Otwieram w przeglądarce stronę z jednolitymi kolorami.
disp_name=Ekran (bez martwych pikseli i prześwitów)
disp_html=Kliknij, aby przejść na pełny ekran.<br>Potem klik lub spacja — następny kolor. Szukaj martwych pikseli, plam i prześwitów.<br>Esc — wyjście.
ask_manual=Uruchomić testy ręczne (klawiatura, głośniki, kamera, ekran)?
s_manual=Testy ręczne
s_summary=Podsumowanie
verdict_fail=Wykryto poważne problemy. Nie kupuj, dopóki nie zostaną usunięte lub cena nie zostanie obniżona.
verdict_warn=Brak krytycznych problemów, ale zwróć uwagę na ostrzeżenia.
verdict_ok=Wszystkie testy automatyczne zakończone pomyślnie.
s_manual_check=Sprawdź również ręcznie
chk_warranty=Gwarancja i data zakupu
serial_lower=numer seryjny
chk_serial=Numer seryjny w systemie zgadza się z tym na spodzie obudowy
chk_diag=Apple Diagnostics: wyłącz Maca i przytrzymaj przycisk zasilania (Apple Silicon) lub D (Intel) podczas włączania
chk_case=Obudowa: wgniecenia, ślady odkręcania śrub, równość pokrywy, luz zawiasu
chk_liquid=Ślady cieczy: plamy na ekranie, lepkie klawisze, korozja portów
chk_ports=Wszystkie porty USB-C/Thunderbolt/HDMI/MagSafe/audio: ładowanie i transfer danych
chk_trackpad=Gładzik: klik na całej powierzchni, Force Touch, gesty; Touch ID; podświetlenie klawiatury
chk_seller=Sprzedawca musi przy Tobie wylogować się z Apple ID, wyłączyć „Znajdź mój Mac” i wymazać Maca
chk_erase=(Ustawienia → Ogólne → Przenieś lub wyzeruj → Wymaż zawartość i ustawienia)
chk_sudo=Uruchomienie przez sudo doda sprawdzenie profili konfiguracyjnych i hasła oprogramowania sprzętowego (Intel).
report_saved=Raport zapisano
err_macos=Ten skrypt działa tylko w macOS.
help_title=sprawdzenie stanu używanego MacBooka
help_usage=Użycie: mac-check.sh [opcje]
help_lang=język interfejsu (domyślnie: język systemu)
help_i=od razu uruchom testy ręczne (klawiatura, dźwięk, kamera, ekran)
help_n=nie proponuj testów ręcznych
help_o=zapisz raport do pliku tekstowego
help_color=bez kolorów
help_h=ta pomoc
help_v=wersja
help_sudo=Uruchomienie przez sudo dodaje sprawdzenie hasła oprogramowania sprzętowego (Intel) i profili konfiguracyjnych oraz pozwala smartctl odczytać zużycie SSD.
EOF
}

catalog_es() { cat <<'EOF'
collecting=Recopilando datos del sistema (10–30 s)…
title=comprobación del estado del Mac
s_system=Sistema
model=Modelo
serial=Número de serie
cpu=Procesador
sec_chip=Chip de seguridad
memory=Memoria
unknown=desconocido
uptime=Tiempo de actividad: %s d %s h %s min
not_laptop=Esto no es un MacBook (%s) — se omitirán las comprobaciones de portátil
s_locks=Bloqueos y registros (¡lo más importante!)
al_off=El Bloqueo de activación está desactivado
al_on=El Bloqueo de activación está ACTIVADO — este Mac está vinculado a un Apple ID
al_on_hint1=El vendedor debe cerrar sesión en su Apple ID y desactivar «Buscar mi Mac» delante de ti.
al_on_hint2=Si no, tras reinstalar macOS el Mac pedirá la contraseña de otra persona.
fmm_on=«Buscar mi Mac» está activado (token FMM en la NVRAM)
al_na=Bloqueo de activación: estado no disponible (Mac sin T2/Apple Silicon)
mdm_na=MDM: no se pudo obtener el estado
dep_yes=El Mac está registrado en un DEP/ABM corporativo — la empresa puede bloquearlo
dep_no=No registrado en DEP / Apple Business Manager
mdm_yes=El Mac está gestionado por MDM (%s) — un dispositivo corporativo
mdm_no=No gestionado por MDM
profiles_yes=Perfiles de configuración instalados: %s (ver Ajustes → Perfiles)
profiles_no=No hay perfiles de configuración
fw_yes=Hay una contraseña de firmware (EFI) — sin ella no se puede arrancar desde otro disco
fw_no=Sin contraseña de firmware
icloud_yes=El usuario actual tiene sesión iniciada en iCloud (%s) — debe cerrarla antes de la venta
icloud_check=Sesión de iCloud: compruébala arriba en Ajustes del Sistema (lo importante es el Bloqueo de activación de arriba)
sip_on=La Protección de la integridad del sistema (SIP) está activada
sip_off=SIP está desactivada o modificada — el sistema ha sido alterado
fv_on=FileVault está activado (normal, pero el vendedor debe borrar el Mac antes de entregarlo)
fv_off=FileVault está desactivado
s_battery=Batería y alimentación
bat_missing=No se detecta la batería — puede estar desconectada o averiada
cycles=Ciclos de carga: %s de %s
cycles_over=vida útil superada
cycles_worn=la batería está bastante desgastada
maxcap=Capacidad máxima
mah=%s de %s mAh
replace=Apple recomienda sustituirla
bat_cond=Estado de la batería según macOS
bat_fake=Muy pocos ciclos con capacidad reducida — la batería podría ser un recambio no original
charge_now=Carga actual
bat_serial=Número de serie de la batería
ac_on=Cargador conectado
watt=W
charging=La batería se está cargando
ac_off=Cargador no conectado — conéctalo para comprobar la carga
no_battery=Sin batería (Mac de sobremesa)
s_storage=Almacenamiento
disk_none=No se pudo detectar la unidad interna
smart_failing=¡la unidad fallará pronto!
smart_na=SMART no disponible
ssd_wear=Desgaste del SSD
ssd_written=Total de datos escritos en el SSD
smart_sudo=smartctl no devolvió datos de desgaste — ejecuta el script con sudo.
smart_nodata=smartctl no devolvió datos de desgaste para esta unidad.
smart_install=Para comprobar el desgaste del SSD, instala smartmontools (brew install smartmontools) y vuelve a ejecutarlo.
sys_volume=Volumen del sistema: %s libres de %s
s_hw=Pantalla, cámara, audio, conexiones inalámbricas
graphics=Gráficos
cores=núcleos
disp_int=Pantalla integrada
disp_ext=Pantalla externa
disp_none=No se detecta la pantalla integrada (¿tapa cerrada? o cable de pantalla averiado)
camera=Cámara
camera_none=No se detecta la cámara
speakers=Altavoces
speakers_none=No se detectan los altavoces integrados
mic=Micrófono
mic_none=No se detecta el micrófono integrado
wifi_ok=Módulo Wi-Fi presente
wifi_none=No se detecta el módulo Wi-Fi
bt_on=activado
bt_none=No se detecta el controlador Bluetooth
s_stability=Estabilidad
panics_none=No hay kernel panics en los registros
panics=Kernel panics: %s, el último %s
panics_hw=posible problema de hardware
panics_hint=Los registros pueden haberse borrado, así que no ver fallos no garantiza estabilidad.
therm_yes=Se ha registrado limitación térmica
therm_no=No se ha registrado limitación térmica
works_q=%s — ¿funciona correctamente?
checked_ok=comprobado manualmente
checked_fail=problema durante la comprobación manual
kb_title=Prueba del teclado.
kb_intro=Cambia la distribución a inglés (EE. UU.) y pulsa cada tecla.
kb_hint=Esc para terminar. Comprueba las teclas modificadoras (⌘ ⌥ ⌃ ⇧ fn) por separado en cualquier app.
kb_left=Restantes
kb_ok=Teclado: todas las teclas probadas funcionan
kb_fail=Teclado: sin pulsar / no funcionan
spk_title=Prueba de altavoces.
spk_intro=Sonará una señal y una voz. Sube el volumen al máximo y escucha si hay chasquidos.
spk_name=Altavoces
cam_title=Prueba de cámara y micrófono.
cam_intro=Abriendo Photo Booth: graba un vídeo corto y reprodúcelo.
cam_name=Cámara y micrófono
disp_title=Prueba de pantalla.
disp_intro=Abriendo en el navegador una página con colores sólidos.
disp_name=Pantalla (sin píxeles muertos ni fugas de luz)
disp_html=Haz clic para ver a pantalla completa.<br>Luego clic o espacio para el siguiente color. Busca píxeles muertos, manchas y fugas de luz.<br>Esc para salir.
ask_manual=¿Ejecutar las pruebas manuales (teclado, altavoces, cámara, pantalla)?
s_manual=Pruebas manuales
s_summary=Resumen
verdict_fail=Se han encontrado problemas graves. No compres hasta que se solucionen o se rebaje el precio.
verdict_warn=No hay problemas críticos, pero revisa las advertencias.
verdict_ok=Todas las comprobaciones automáticas superadas.
s_manual_check=Comprueba también a mano
chk_warranty=Garantía y fecha de compra
serial_lower=número de serie
chk_serial=El número de serie del sistema coincide con el impreso en la base de la carcasa
chk_diag=Diagnóstico Apple: apaga el Mac y mantén pulsado el botón de encendido (Apple Silicon) o D (Intel) al arrancar
chk_case=Carcasa: golpes, marcas de tornillos abiertos, alineación de la tapa, holgura de la bisagra
chk_liquid=Daños por líquido: manchas en la pantalla, teclas pegajosas, puertos oxidados
chk_ports=Todos los puertos USB-C/Thunderbolt/HDMI/MagSafe/audio: carga y transferencia de datos
chk_trackpad=Trackpad: clic en toda la superficie, Force Touch, gestos; Touch ID; retroiluminación del teclado
chk_seller=El vendedor debe, delante de ti, cerrar sesión en su Apple ID, desactivar «Buscar mi Mac» y borrar el Mac
chk_erase=(Ajustes → General → Transferir o restablecer → Borrar contenidos y ajustes)
chk_sudo=Ejecutarlo con sudo añade la comprobación de perfiles de configuración y de la contraseña de firmware (Intel).
report_saved=Informe guardado
err_macos=Este script solo funciona en macOS.
help_title=comprobación del estado de un MacBook usado
help_usage=Uso: mac-check.sh [opciones]
help_lang=idioma de la interfaz (por defecto: idioma del sistema)
help_i=ejecutar directamente las pruebas manuales (teclado, sonido, cámara, pantalla)
help_n=no ofrecer las pruebas manuales
help_o=guardar el informe en un archivo de texto
help_color=sin colores
help_h=esta ayuda
help_v=versión
help_sudo=Con sudo se comprueban además la contraseña de firmware (Intel) y los perfiles de configuración, y smartctl puede leer el desgaste del SSD.
EOF
}

catalog_fr() { cat <<'EOF'
collecting=Collecte des données système (10–30 s)…
title=vérification de l’état du Mac
s_system=Système
model=Modèle
serial=Numéro de série
cpu=Processeur
sec_chip=Puce de sécurité
memory=Mémoire
unknown=inconnu
uptime=Temps de fonctionnement : %s j %s h %s min
not_laptop=Ce n’est pas un MacBook (%s) — les vérifications propres aux portables seront ignorées
s_locks=Verrouillages et inscriptions (le plus important !)
al_off=Le verrouillage d’activation est désactivé
al_on=Le verrouillage d’activation est ACTIVÉ — ce Mac est lié à un identifiant Apple
al_on_hint1=Le vendeur doit se déconnecter de son identifiant Apple et désactiver « Localiser mon Mac » devant vous.
al_on_hint2=Sinon, après réinstallation de macOS, le Mac demandera le mot de passe de quelqu’un d’autre.
fmm_on=« Localiser mon Mac » est activé (jeton FMM dans la NVRAM)
al_na=Verrouillage d’activation : état indisponible (Mac sans T2/Apple Silicon)
mdm_na=MDM : impossible d’obtenir l’état
dep_yes=Le Mac est inscrit dans un DEP/ABM d’entreprise — l’entreprise peut le verrouiller
dep_no=Non inscrit dans DEP / Apple Business Manager
mdm_yes=Le Mac est géré par MDM (%s) — un appareil d’entreprise
mdm_no=Non géré par MDM
profiles_yes=Profils de configuration installés : %s (voir Réglages → Profils)
profiles_no=Aucun profil de configuration
fw_yes=Un mot de passe du firmware (EFI) est défini — impossible de démarrer sur un autre disque sans lui
fw_no=Pas de mot de passe du firmware
icloud_yes=L’utilisateur actuel est connecté à iCloud (%s) — il doit se déconnecter avant la vente
icloud_check=Connexion iCloud : vérifiez en haut des Réglages Système (l’essentiel est le verrouillage d’activation ci-dessus)
sip_on=La protection de l’intégrité du système (SIP) est activée
sip_off=SIP est désactivée ou modifiée — le système a été altéré
fv_on=FileVault est activé (normal, mais le vendeur doit effacer le Mac avant de le remettre)
fv_off=FileVault est désactivé
s_battery=Batterie et alimentation
bat_missing=Batterie non détectée — elle est peut-être débranchée ou défectueuse
cycles=Cycles de charge : %s sur %s
cycles_over=durée de vie dépassée
cycles_worn=batterie assez usée
maxcap=Capacité maximale
mah=%s sur %s mAh
replace=Apple recommande le remplacement
bat_cond=État de la batterie selon macOS
bat_fake=Très peu de cycles avec une capacité réduite — la batterie a peut-être été remplacée par une pièce non d’origine
charge_now=Charge actuelle
bat_serial=Numéro de série de la batterie
ac_on=Chargeur branché
watt=W
charging=La batterie est en charge
ac_off=Chargeur non branché — branchez-le pour vérifier la charge
no_battery=Pas de batterie (Mac de bureau)
s_storage=Stockage
disk_none=Impossible de détecter le disque interne
smart_failing=le disque va bientôt tomber en panne !
smart_na=SMART indisponible
ssd_wear=Usure du SSD
ssd_written=Total des données écrites sur le SSD
smart_sudo=smartctl n’a renvoyé aucune donnée d’usure — lancez le script avec sudo.
smart_nodata=smartctl n’a renvoyé aucune donnée d’usure pour ce disque.
smart_install=Pour vérifier l’usure du SSD, installez smartmontools (brew install smartmontools) et relancez.
sys_volume=Volume système : %s libres sur %s
s_hw=Écran, caméra, audio, sans fil
graphics=Graphismes
cores=cœurs
disp_int=Écran intégré
disp_ext=Écran externe
disp_none=Écran intégré non détecté (capot fermé ? ou nappe d’écran défectueuse)
camera=Caméra
camera_none=Caméra non détectée
speakers=Haut-parleurs
speakers_none=Haut-parleurs intégrés non détectés
mic=Microphone
mic_none=Microphone intégré non détecté
wifi_ok=Module Wi-Fi présent
wifi_none=Module Wi-Fi non détecté
bt_on=activé
bt_none=Contrôleur Bluetooth non détecté
s_stability=Stabilité
panics_none=Aucun kernel panic dans les journaux
panics=Kernel panics : %s, le dernier le %s
panics_hw=problème matériel possible
panics_hint=Les journaux ont pu être effacés : l’absence de plantages ne garantit pas la stabilité.
therm_yes=Bridage thermique enregistré
therm_no=Aucun bridage thermique enregistré
works_q=%s — fonctionne correctement ?
checked_ok=vérifié manuellement
checked_fail=problème lors de la vérification manuelle
kb_title=Test du clavier.
kb_intro=Passez en disposition anglaise (US) et appuyez sur chaque touche.
kb_hint=Échap pour terminer. Vérifiez les touches de modification (⌘ ⌥ ⌃ ⇧ fn) séparément dans n’importe quelle app.
kb_left=Restantes
kb_ok=Clavier : toutes les touches testées fonctionnent
kb_fail=Clavier : non pressées / ne fonctionnent pas
spk_title=Test des haut-parleurs.
spk_intro=Un signal et une voix vont être joués. Montez le volume au maximum et écoutez s’il y a des grésillements.
spk_name=Haut-parleurs
cam_title=Test de la caméra et du microphone.
cam_intro=Ouverture de Photo Booth : enregistrez une courte vidéo et relisez-la.
cam_name=Caméra et microphone
disp_title=Test de l’écran.
disp_intro=Ouverture dans le navigateur d’une page aux couleurs unies.
disp_name=Écran (sans pixels morts ni fuites de lumière)
disp_html=Cliquez pour passer en plein écran.<br>Puis clic ou Espace pour la couleur suivante. Cherchez pixels morts, taches et fuites de lumière.<br>Échap pour quitter.
ask_manual=Lancer les tests manuels (clavier, haut-parleurs, caméra, écran) ?
s_manual=Tests manuels
s_summary=Résumé
verdict_fail=Problèmes graves détectés. N’achetez pas tant qu’ils ne sont pas corrigés ou que le prix n’est pas baissé.
verdict_warn=Aucun problème critique, mais lisez les avertissements.
verdict_ok=Toutes les vérifications automatiques sont réussies.
s_manual_check=À vérifier aussi à la main
chk_warranty=Garantie et date d’achat
serial_lower=numéro de série
chk_serial=Le numéro de série du système correspond à celui imprimé sous le boîtier
chk_diag=Diagnostics Apple : éteignez le Mac, puis maintenez le bouton d’alimentation (Apple Silicon) ou D (Intel) au démarrage
chk_case=Boîtier : bosses, traces de vis ouvertes, alignement de l’écran, jeu de la charnière
chk_liquid=Dégâts de liquide : taches sur l’écran, touches collantes, ports oxydés
chk_ports=Tous les ports USB-C/Thunderbolt/HDMI/MagSafe/audio : charge et transfert de données
chk_trackpad=Trackpad : clic sur toute la surface, Force Touch, gestes ; Touch ID ; rétroéclairage du clavier
chk_seller=Le vendeur doit, devant vous, se déconnecter de son identifiant Apple, désactiver « Localiser mon Mac » et effacer le Mac
chk_erase=(Réglages → Général → Transférer ou réinitialiser → Effacer contenu et réglages)
chk_sudo=Lancer avec sudo ajoute la vérification des profils de configuration et du mot de passe du firmware (Intel).
report_saved=Rapport enregistré
err_macos=Ce script ne fonctionne que sous macOS.
help_title=vérification de l’état d’un MacBook d’occasion
help_usage=Utilisation : mac-check.sh [options]
help_lang=langue de l’interface (par défaut : langue du système)
help_i=lancer directement les tests manuels (clavier, son, caméra, écran)
help_n=ne pas proposer les tests manuels
help_o=enregistrer le rapport dans un fichier texte
help_color=sans couleurs
help_h=cette aide
help_v=version
help_sudo=Avec sudo : vérification du mot de passe du firmware (Intel) et des profils de configuration, et lecture de l’usure du SSD par smartctl.
EOF
}

catalog_it() { cat <<'EOF'
collecting=Raccolta dei dati di sistema (10–30 s)…
title=controllo dello stato del Mac
s_system=Sistema
model=Modello
serial=Numero di serie
cpu=Processore
sec_chip=Chip di sicurezza
memory=Memoria
unknown=sconosciuto
uptime=Tempo di attività: %s g %s h %s min
not_laptop=Questo non è un MacBook (%s) — i controlli specifici per portatili saranno saltati
s_locks=Blocchi e registrazioni (la parte più importante!)
al_off=Il blocco attivazione è disattivato
al_on=Il blocco attivazione è ATTIVO — questo Mac è collegato a un ID Apple
al_on_hint1=Il venditore deve uscire dal proprio ID Apple e disattivare «Trova il mio Mac» davanti a te.
al_on_hint2=Altrimenti, dopo la reinstallazione di macOS, il Mac chiederà la password di un’altra persona.
fmm_on=«Trova il mio Mac» è attivo (token FMM nella NVRAM)
al_na=Blocco attivazione: stato non disponibile (Mac senza T2/Apple Silicon)
mdm_na=MDM: impossibile ottenere lo stato
dep_yes=Il Mac è registrato in un DEP/ABM aziendale — l’azienda può bloccarlo
dep_no=Non registrato in DEP / Apple Business Manager
mdm_yes=Il Mac è gestito tramite MDM (%s) — un dispositivo aziendale
mdm_no=Non gestito tramite MDM
profiles_yes=Profili di configurazione installati: %s (vedi Impostazioni → Profili)
profiles_no=Nessun profilo di configurazione
fw_yes=È impostata una password del firmware (EFI) — senza di essa non si avvia da un altro disco
fw_no=Nessuna password del firmware
icloud_yes=L’utente attuale ha effettuato l’accesso a iCloud (%s) — deve uscire prima della vendita
icloud_check=Accesso a iCloud: controlla in cima a Impostazioni di Sistema (conta soprattutto il blocco attivazione sopra)
sip_on=La protezione dell’integrità del sistema (SIP) è attiva
sip_off=SIP è disattivata o modificata — il sistema è stato alterato
fv_on=FileVault è attivo (va bene, ma il venditore deve inizializzare il Mac prima della consegna)
fv_off=FileVault è disattivato
s_battery=Batteria e alimentazione
bat_missing=Batteria non rilevata — potrebbe essere scollegata o guasta
cycles=Cicli di ricarica: %s su %s
cycles_over=durata prevista superata
cycles_worn=batteria piuttosto usurata
maxcap=Capacità massima
mah=%s su %s mAh
replace=Apple consiglia la sostituzione
bat_cond=Condizione della batteria secondo macOS
bat_fake=Pochissimi cicli con capacità ridotta — la batteria potrebbe essere un ricambio non originale
charge_now=Carica attuale
bat_serial=Numero di serie della batteria
ac_on=Alimentatore collegato
watt=W
charging=La batteria è in carica
ac_off=Alimentatore non collegato — collegalo per verificare la ricarica
no_battery=Nessuna batteria (Mac desktop)
s_storage=Archiviazione
disk_none=Impossibile rilevare l’unità interna
smart_failing=l’unità si guasterà presto!
smart_na=SMART non disponibile
ssd_wear=Usura dell’SSD
ssd_written=Dati totali scritti sull’SSD
smart_sudo=smartctl non ha restituito dati sull’usura — esegui lo script con sudo.
smart_nodata=smartctl non ha restituito dati sull’usura per questa unità.
smart_install=Per controllare l’usura dell’SSD installa smartmontools (brew install smartmontools) ed esegui di nuovo.
sys_volume=Volume di sistema: %s liberi su %s
s_hw=Schermo, fotocamera, audio, wireless
graphics=Grafica
cores=core
disp_int=Schermo integrato
disp_ext=Schermo esterno
disp_none=Schermo integrato non rilevato (coperchio chiuso? o cavo dello schermo guasto)
camera=Fotocamera
camera_none=Fotocamera non rilevata
speakers=Altoparlanti
speakers_none=Altoparlanti integrati non rilevati
mic=Microfono
mic_none=Microfono integrato non rilevato
wifi_ok=Modulo Wi-Fi presente
wifi_none=Modulo Wi-Fi non rilevato
bt_on=attivo
bt_none=Controller Bluetooth non rilevato
s_stability=Stabilità
panics_none=Nessun kernel panic nei log
panics=Kernel panic: %s, l’ultimo il %s
panics_hw=possibile problema hardware
panics_hint=I log potrebbero essere stati cancellati: l’assenza di crash non garantisce la stabilità.
therm_yes=Rilevata limitazione termica
therm_no=Nessuna limitazione termica rilevata
works_q=%s — funziona correttamente?
checked_ok=verificato manualmente
checked_fail=problema durante la verifica manuale
kb_title=Test della tastiera.
kb_intro=Passa al layout inglese (US) e premi ogni tasto.
kb_hint=Esc per terminare. Controlla i tasti modificatori (⌘ ⌥ ⌃ ⇧ fn) separatamente in qualsiasi app.
kb_left=Rimanenti
kb_ok=Tastiera: tutti i tasti provati funzionano
kb_fail=Tastiera: non premuti / non funzionanti
spk_title=Test degli altoparlanti.
spk_intro=Verranno riprodotti un segnale e una voce. Alza il volume al massimo e ascolta se ci sono gracchi.
spk_name=Altoparlanti
cam_title=Test di fotocamera e microfono.
cam_intro=Apro Photo Booth: registra un breve video e riguardalo.
cam_name=Fotocamera e microfono
disp_title=Test dello schermo.
disp_intro=Apro nel browser una pagina con colori pieni.
disp_name=Schermo (senza pixel morti né aloni di luce)
disp_html=Fai clic per passare a schermo intero.<br>Poi clic o Spazio per il colore successivo. Cerca pixel morti, macchie e aloni di luce.<br>Esc per uscire.
ask_manual=Eseguire i test manuali (tastiera, altoparlanti, fotocamera, schermo)?
s_manual=Test manuali
s_summary=Riepilogo
verdict_fail=Trovati problemi gravi. Non comprare finché non vengono risolti o il prezzo non viene abbassato.
verdict_warn=Nessun problema critico, ma controlla gli avvisi.
verdict_ok=Tutti i controlli automatici superati.
s_manual_check=Controlla anche a mano
chk_warranty=Garanzia e data di acquisto
serial_lower=numero di serie
chk_serial=Il numero di serie nel sistema corrisponde a quello stampato sotto la scocca
chk_diag=Diagnostica Apple: spegni il Mac, poi tieni premuto il tasto di accensione (Apple Silicon) o D (Intel) all’avvio
chk_case=Scocca: ammaccature, segni di viti svitate, allineamento del coperchio, gioco della cerniera
chk_liquid=Danni da liquidi: macchie sullo schermo, tasti appiccicosi, porte ossidate
chk_ports=Tutte le porte USB-C/Thunderbolt/HDMI/MagSafe/audio: ricarica e trasferimento dati
chk_trackpad=Trackpad: clic su tutta la superficie, Force Touch, gesti; Touch ID; retroilluminazione della tastiera
chk_seller=Il venditore deve, davanti a te, uscire dall’ID Apple, disattivare «Trova il mio Mac» e inizializzare il Mac
chk_erase=(Impostazioni → Generali → Trasferisci o ripristina → Cancella contenuto e impostazioni)
chk_sudo=Eseguendo con sudo si aggiungono i controlli dei profili di configurazione e della password del firmware (Intel).
report_saved=Rapporto salvato
err_macos=Questo script funziona solo su macOS.
help_title=controllo dello stato di un MacBook usato
help_usage=Uso: mac-check.sh [opzioni]
help_lang=lingua dell’interfaccia (predefinita: lingua del sistema)
help_i=avvia subito i test manuali (tastiera, audio, fotocamera, schermo)
help_n=non proporre i test manuali
help_o=salva il rapporto in un file di testo
help_color=senza colori
help_h=questa guida
help_v=versione
help_sudo=Con sudo si controllano anche la password del firmware (Intel) e i profili di configurazione, e smartctl può leggere l’usura dell’SSD.
EOF
}

catalog_pt() { cat <<'EOF'
collecting=A recolher dados do sistema (10–30 s)…
title=verificação do estado do Mac
s_system=Sistema
model=Modelo
serial=Número de série
cpu=Processador
sec_chip=Chip de segurança
memory=Memória
unknown=desconhecido
uptime=Tempo de atividade: %s d %s h %s min
not_laptop=Isto não é um MacBook (%s) — as verificações próprias de portáteis serão ignoradas
s_locks=Bloqueios e registos (o mais importante!)
al_off=O Bloqueio de Ativação está desativado
al_on=O Bloqueio de Ativação está ATIVADO — este Mac está associado a um ID Apple
al_on_hint1=O vendedor tem de terminar sessão no ID Apple e desativar «Encontrar o meu Mac» à sua frente.
al_on_hint2=Caso contrário, após reinstalar o macOS, o Mac vai pedir a palavra-passe de outra pessoa.
fmm_on=«Encontrar o meu Mac» está ativado (token FMM na NVRAM)
al_na=Bloqueio de Ativação: estado indisponível (Mac sem T2/Apple Silicon)
mdm_na=MDM: não foi possível obter o estado
dep_yes=O Mac está registado num DEP/ABM empresarial — a empresa pode bloqueá-lo
dep_no=Não registado no DEP / Apple Business Manager
mdm_yes=O Mac é gerido por MDM (%s) — um dispositivo empresarial
mdm_no=Não gerido por MDM
profiles_yes=Perfis de configuração instalados: %s (ver Definições → Perfis)
profiles_no=Sem perfis de configuração
fw_yes=Existe uma palavra-passe de firmware (EFI) — sem ela não é possível arrancar a partir de outro disco
fw_no=Sem palavra-passe de firmware
icloud_yes=O utilizador atual tem sessão iniciada no iCloud (%s) — deve terminá-la antes da venda
icloud_check=Sessão no iCloud: verifique no topo das Definições do Sistema (o essencial é o Bloqueio de Ativação acima)
sip_on=A Proteção da Integridade do Sistema (SIP) está ativada
sip_off=A SIP está desativada ou alterada — o sistema foi modificado
fv_on=O FileVault está ativado (normal, mas o vendedor deve apagar o Mac antes da entrega)
fv_off=O FileVault está desativado
s_battery=Bateria e alimentação
bat_missing=Bateria não detetada — pode estar desligada ou avariada
cycles=Ciclos de carga: %s de %s
cycles_over=vida útil ultrapassada
cycles_worn=bateria bastante desgastada
maxcap=Capacidade máxima
mah=%s de %s mAh
replace=A Apple recomenda a substituição
bat_cond=Estado da bateria segundo o macOS
bat_fake=Muito poucos ciclos com capacidade reduzida — a bateria pode ser uma substituição não original
charge_now=Carga atual
bat_serial=Número de série da bateria
ac_on=Carregador ligado
watt=W
charging=A bateria está a carregar
ac_off=Carregador não ligado — ligue-o para verificar o carregamento
no_battery=Sem bateria (Mac de secretária)
s_storage=Armazenamento
disk_none=Não foi possível detetar a unidade interna
smart_failing=a unidade vai falhar em breve!
smart_na=SMART indisponível
ssd_wear=Desgaste do SSD
ssd_written=Total de dados escritos no SSD
smart_sudo=O smartctl não devolveu dados de desgaste — execute o script com sudo.
smart_nodata=O smartctl não devolveu dados de desgaste para esta unidade.
smart_install=Para verificar o desgaste do SSD, instale o smartmontools (brew install smartmontools) e execute novamente.
sys_volume=Volume do sistema: %s livres de %s
s_hw=Ecrã, câmara, áudio, sem fios
graphics=Gráficos
cores=núcleos
disp_int=Ecrã integrado
disp_ext=Ecrã externo
disp_none=Ecrã integrado não detetado (tampa fechada? ou cabo do ecrã avariado)
camera=Câmara
camera_none=Câmara não detetada
speakers=Altifalantes
speakers_none=Altifalantes integrados não detetados
mic=Microfone
mic_none=Microfone integrado não detetado
wifi_ok=Módulo Wi-Fi presente
wifi_none=Módulo Wi-Fi não detetado
bt_on=ativado
bt_none=Controlador Bluetooth não detetado
s_stability=Estabilidade
panics_none=Sem kernel panics nos registos
panics=Kernel panics: %s, o último em %s
panics_hw=possível problema de hardware
panics_hint=Os registos podem ter sido apagados, por isso a ausência de falhas não garante estabilidade.
therm_yes=Foi registada limitação térmica
therm_no=Nenhuma limitação térmica registada
works_q=%s — funciona corretamente?
checked_ok=verificado manualmente
checked_fail=problema na verificação manual
kb_title=Teste do teclado.
kb_intro=Mude para o esquema inglês (EUA) e prima cada tecla.
kb_hint=Esc para terminar. Verifique as teclas modificadoras (⌘ ⌥ ⌃ ⇧ fn) em separado em qualquer app.
kb_left=Restantes
kb_ok=Teclado: todas as teclas testadas funcionam
kb_fail=Teclado: não premidas / não funcionam
spk_title=Teste dos altifalantes.
spk_intro=Vai ouvir um sinal e uma voz. Ponha o volume no máximo e repare se há estalidos.
spk_name=Altifalantes
cam_title=Teste da câmara e do microfone.
cam_intro=A abrir o Photo Booth: grave um vídeo curto e reproduza-o.
cam_name=Câmara e microfone
disp_title=Teste do ecrã.
disp_intro=A abrir no navegador uma página com cores sólidas.
disp_name=Ecrã (sem píxeis mortos nem fugas de luz)
disp_html=Clique para ecrã inteiro.<br>Depois clique ou prima Espaço para a cor seguinte. Procure píxeis mortos, manchas e fugas de luz.<br>Esc para sair.
ask_manual=Executar os testes manuais (teclado, altifalantes, câmara, ecrã)?
s_manual=Testes manuais
s_summary=Resumo
verdict_fail=Foram encontrados problemas graves. Não compre até serem resolvidos ou o preço baixar.
verdict_warn=Sem problemas críticos, mas reveja os avisos.
verdict_ok=Todas as verificações automáticas foram aprovadas.
s_manual_check=Verifique também à mão
chk_warranty=Garantia e data de compra
serial_lower=número de série
chk_serial=O número de série no sistema coincide com o impresso na base da caixa
chk_diag=Diagnóstico Apple: desligue o Mac e mantenha premido o botão de alimentação (Apple Silicon) ou D (Intel) ao arrancar
chk_case=Caixa: amolgadelas, marcas de parafusos abertos, alinhamento da tampa, folga da dobradiça
chk_liquid=Danos por líquidos: manchas no ecrã, teclas pegajosas, portas oxidadas
chk_ports=Todas as portas USB-C/Thunderbolt/HDMI/MagSafe/áudio: carregamento e transferência de dados
chk_trackpad=Trackpad: clique em toda a superfície, Force Touch, gestos; Touch ID; retroiluminação do teclado
chk_seller=O vendedor tem de, à sua frente, terminar sessão no ID Apple, desativar «Encontrar o meu Mac» e apagar o Mac
chk_erase=(Definições → Geral → Transferir ou repor → Apagar conteúdo e definições)
chk_sudo=Executar com sudo acrescenta a verificação dos perfis de configuração e da palavra-passe de firmware (Intel).
report_saved=Relatório guardado
err_macos=Este script só funciona no macOS.
help_title=verificação do estado de um MacBook usado
help_usage=Utilização: mac-check.sh [opções]
help_lang=idioma da interface (predefinição: idioma do sistema)
help_i=executar já os testes manuais (teclado, som, câmara, ecrã)
help_n=não propor os testes manuais
help_o=guardar o relatório num ficheiro de texto
help_color=sem cores
help_h=esta ajuda
help_v=versão
help_sudo=Com sudo verificam-se também a palavra-passe de firmware (Intel) e os perfis de configuração, e o smartctl pode ler o desgaste do SSD.
EOF
}

catalog_nl() { cat <<'EOF'
collecting=Systeemgegevens verzamelen (10–30 s)…
title=Mac-conditiecontrole
s_system=Systeem
model=Model
serial=Serienummer
cpu=Processor
sec_chip=Beveiligingschip
memory=Geheugen
unknown=onbekend
uptime=Actief sinds laatste start: %s d %s u %s min
not_laptop=Dit is geen MacBook (%s) — controles voor laptops worden overgeslagen
s_locks=Vergrendelingen en registraties (het belangrijkst!)
al_off=Activeringsslot staat uit
al_on=Activeringsslot staat AAN — deze Mac is gekoppeld aan een Apple ID
al_on_hint1=De verkoper moet in uw bijzijn uitloggen bij de Apple ID en ‘Zoek mijn Mac’ uitschakelen.
al_on_hint2=Anders vraagt de Mac na herinstallatie van macOS om het wachtwoord van iemand anders.
fmm_on=‘Zoek mijn Mac’ staat aan (FMM-token in NVRAM)
al_na=Activeringsslot: status niet beschikbaar (Mac zonder T2/Apple Silicon)
mdm_na=MDM: status kon niet worden opgehaald
dep_yes=De Mac is geregistreerd in een zakelijk DEP/ABM — het bedrijf kan hem vergrendelen
dep_no=Niet geregistreerd in DEP / Apple Business Manager
mdm_yes=De Mac wordt beheerd via MDM (%s) — een bedrijfsapparaat
mdm_no=Niet beheerd via MDM
profiles_yes=Geïnstalleerde configuratieprofielen: %s (zie Instellingen → Profielen)
profiles_no=Geen configuratieprofielen
fw_yes=Er is een firmwarewachtwoord (EFI) ingesteld — zonder dat kan niet van een andere schijf worden opgestart
fw_no=Geen firmwarewachtwoord
icloud_yes=De huidige gebruiker is ingelogd bij iCloud (%s) — moet vóór de verkoop uitloggen
icloud_check=iCloud-login: controleer bovenaan Systeeminstellingen (het activeringsslot hierboven is waar het om gaat)
sip_on=Systeemintegriteitsbescherming (SIP) staat aan
sip_off=SIP staat uit of is aangepast — het systeem is gewijzigd
fv_on=FileVault staat aan (prima, maar de verkoper moet de Mac vóór overdracht wissen)
fv_off=FileVault staat uit
s_battery=Batterij en voeding
bat_missing=Batterij niet gedetecteerd — mogelijk losgekoppeld of defect
cycles=Laadcycli: %s van %s
cycles_over=levensduur overschreden
cycles_worn=batterij is behoorlijk versleten
maxcap=Maximale capaciteit
mah=%s van %s mAh
replace=Apple raadt vervanging aan
bat_cond=Batterijconditie volgens macOS
bat_fake=Zeer weinig cycli bij verminderde capaciteit — mogelijk een niet-originele vervangende batterij
charge_now=Huidige lading
bat_serial=Serienummer van de batterij
ac_on=Lader aangesloten
watt=W
charging=Batterij wordt opgeladen
ac_off=Lader niet aangesloten — sluit hem aan om het opladen te controleren
no_battery=Geen batterij (desktop-Mac)
s_storage=Opslag
disk_none=Interne schijf kon niet worden gedetecteerd
smart_failing=de schijf gaat binnenkort kapot!
smart_na=SMART niet beschikbaar
ssd_wear=SSD-slijtage
ssd_written=Totaal naar de SSD geschreven
smart_sudo=smartctl gaf geen slijtagegegevens — voer het script uit met sudo.
smart_nodata=smartctl gaf geen slijtagegegevens voor deze schijf.
smart_install=Installeer smartmontools (brew install smartmontools) en voer opnieuw uit om de SSD-slijtage te controleren.
sys_volume=Systeemvolume: %s vrij van %s
s_hw=Beeldscherm, camera, audio, draadloos
graphics=Grafisch
cores=kernen
disp_int=Ingebouwd beeldscherm
disp_ext=Extern beeldscherm
disp_none=Ingebouwd beeldscherm niet gedetecteerd (deksel dicht? of defecte schermkabel)
camera=Camera
camera_none=Camera niet gedetecteerd
speakers=Luidsprekers
speakers_none=Ingebouwde luidsprekers niet gedetecteerd
mic=Microfoon
mic_none=Ingebouwde microfoon niet gedetecteerd
wifi_ok=Wi-Fi-module aanwezig
wifi_none=Wi-Fi-module niet gedetecteerd
bt_on=aan
bt_none=Bluetooth-controller niet gedetecteerd
s_stability=Stabiliteit
panics_none=Geen kernel panics in de logboeken
panics=Kernel panics: %s, laatste op %s
panics_hw=mogelijk hardwareprobleem
panics_hint=Logboeken kunnen gewist zijn, dus geen crashes garandeert geen stabiliteit.
therm_yes=Thermische throttling geregistreerd
therm_no=Geen thermische throttling geregistreerd
works_q=%s — werkt het goed?
checked_ok=handmatig gecontroleerd
checked_fail=probleem bij handmatige controle
kb_title=Toetsenbordtest.
kb_intro=Schakel over naar de Engelse (VS) indeling en druk op elke toets.
kb_hint=Esc om te stoppen. Controleer speciale toetsen (⌘ ⌥ ⌃ ⇧ fn) apart in een willekeurige app.
kb_left=Resterend
kb_ok=Toetsenbord: alle geteste toetsen werken
kb_fail=Toetsenbord: niet ingedrukt / werkt niet
spk_title=Luidsprekertest.
spk_intro=Er klinkt een signaal en een stem. Zet het volume op maximaal en luister naar gekraak.
spk_name=Luidsprekers
cam_title=Camera- en microfoontest.
cam_intro=Photo Booth wordt geopend: neem een korte video op en speel die af.
cam_name=Camera en microfoon
disp_title=Beeldschermtest.
disp_intro=Er wordt een pagina met effen kleuren in de browser geopend.
disp_name=Beeldscherm (zonder dode pixels of lichtlekkage)
disp_html=Klik voor volledig scherm.<br>Daarna klik of spatie voor de volgende kleur. Let op dode pixels, vlekken en lichtlekkage.<br>Esc om te sluiten.
ask_manual=Handmatige tests uitvoeren (toetsenbord, luidsprekers, camera, beeldscherm)?
s_manual=Handmatige tests
s_summary=Samenvatting
verdict_fail=Ernstige problemen gevonden. Niet kopen tot ze zijn opgelost of de prijs omlaag gaat.
verdict_warn=Geen kritieke problemen, maar bekijk de waarschuwingen.
verdict_ok=Alle automatische controles geslaagd.
s_manual_check=Controleer ook handmatig
chk_warranty=Garantie en aankoopdatum
serial_lower=serienummer
chk_serial=Het serienummer in het systeem komt overeen met dat op de onderkant van de behuizing
chk_diag=Apple Diagnostics: zet de Mac uit en houd bij het opstarten de aan/uit-knop (Apple Silicon) of D (Intel) ingedrukt
chk_case=Behuizing: deuken, sporen van geopende schroeven, uitlijning van het deksel, speling in het scharnier
chk_liquid=Vloeistofschade: vlekken op het scherm, plakkerige toetsen, gecorrodeerde poorten
chk_ports=Alle USB-C/Thunderbolt/HDMI/MagSafe/audiopoorten: opladen en gegevensoverdracht
chk_trackpad=Trackpad: klik over het hele oppervlak, Force Touch, gebaren; Touch ID; toetsenbordverlichting
chk_seller=De verkoper moet in uw bijzijn uitloggen bij de Apple ID, ‘Zoek mijn Mac’ uitschakelen en de Mac wissen
chk_erase=(Instellingen → Algemeen → Zet over of stel opnieuw in → Wis alle inhoud en instellingen)
chk_sudo=Uitvoeren met sudo voegt controles toe van configuratieprofielen en het firmwarewachtwoord (Intel).
report_saved=Rapport opgeslagen
err_macos=Dit script werkt alleen op macOS.
help_title=conditiecontrole voor een gebruikte MacBook
help_usage=Gebruik: mac-check.sh [opties]
help_lang=taal van de interface (standaard: systeemtaal)
help_i=handmatige tests direct starten (toetsenbord, geluid, camera, beeldscherm)
help_n=geen handmatige tests aanbieden
help_o=rapport opslaan in een tekstbestand
help_color=zonder kleuren
help_h=deze hulp
help_v=versie
help_sudo=Met sudo worden ook het firmwarewachtwoord (Intel) en configuratieprofielen gecontroleerd, en kan smartctl de SSD-slijtage lezen.
EOF
}

catalog_cs() { cat <<'EOF'
collecting=Shromažďuji údaje o systému (10–30 s)…
title=kontrola stavu Macu
s_system=Systém
model=Model
serial=Sériové číslo
cpu=Procesor
sec_chip=Bezpečnostní čip
memory=Paměť
unknown=neznámé
uptime=Doba běhu od posledního spuštění: %s d %s h %s min
not_laptop=Toto není MacBook (%s) — kontroly určené pro notebooky budou přeskočeny
s_locks=Zámky a registrace (nejdůležitější!)
al_off=Zámek aktivace je vypnutý
al_on=Zámek aktivace je ZAPNUTÝ — tento Mac je svázán s Apple ID
al_on_hint1=Prodávající se musí před vámi odhlásit z Apple ID a vypnout „Najít Mac“.
al_on_hint2=Jinak bude Mac po přeinstalaci macOS vyžadovat cizí heslo.
fmm_on=„Najít Mac“ je zapnuté (token FMM v NVRAM)
al_na=Zámek aktivace: stav není dostupný (Mac bez T2/Apple Silicon)
mdm_na=MDM: stav se nepodařilo zjistit
dep_yes=Mac je registrován ve firemním DEP/ABM — firma ho může zablokovat
dep_no=Není registrován v DEP / Apple Business Manager
mdm_yes=Mac je spravován přes MDM (%s) — firemní zařízení
mdm_no=Není spravován přes MDM
profiles_yes=Nainstalované konfigurační profily: %s (viz Nastavení → Profily)
profiles_no=Žádné konfigurační profily
fw_yes=Je nastaveno heslo firmwaru (EFI) — bez něj nelze spustit Mac z jiného disku
fw_no=Heslo firmwaru není nastaveno
icloud_yes=Aktuální uživatel je přihlášen k iCloudu (%s) — před prodejem se musí odhlásit
icloud_check=Přihlášení k iCloudu: zkontrolujte nahoře v Nastavení systému (podstatný je zámek aktivace výše)
sip_on=Ochrana integrity systému (SIP) je zapnutá
sip_off=SIP je vypnutá nebo upravená — systém byl změněn
fv_on=FileVault je zapnutý (v pořádku, ale prodávající musí Mac před předáním vymazat)
fv_off=FileVault je vypnutý
s_battery=Baterie a napájení
bat_missing=Baterie nebyla rozpoznána — může být odpojená nebo vadná
cycles=Nabíjecí cykly: %s z %s
cycles_over=životnost překročena
cycles_worn=baterie je značně opotřebovaná
maxcap=Maximální kapacita
mah=%s z %s mAh
replace=Apple doporučuje výměnu
bat_cond=Stav baterie podle macOS
bat_fake=Velmi málo cyklů při snížené kapacitě — baterie může být neoriginální náhrada
charge_now=Aktuální nabití
bat_serial=Sériové číslo baterie
ac_on=Nabíječka připojena
watt=W
charging=Baterie se nabíjí
ac_off=Nabíječka není připojena — připojte ji a ověřte nabíjení
no_battery=Bez baterie (stolní Mac)
s_storage=Úložiště
disk_none=Interní disk se nepodařilo rozpoznat
smart_failing=disk brzy selže!
smart_na=SMART není dostupný
ssd_wear=Opotřebení SSD
ssd_written=Celkem zapsáno na SSD
smart_sudo=smartctl nevrátil údaje o opotřebení — spusťte skript přes sudo.
smart_nodata=smartctl nevrátil údaje o opotřebení pro tento disk.
smart_install=Pro kontrolu opotřebení SSD nainstalujte smartmontools (brew install smartmontools) a spusťte znovu.
sys_volume=Systémový svazek: volno %s z %s
s_hw=Displej, kamera, zvuk, bezdrátové moduly
graphics=Grafika
cores=jader
disp_int=Vestavěný displej
disp_ext=Externí displej
disp_none=Vestavěný displej nebyl rozpoznán (zavřené víko? nebo vadný kabel displeje)
camera=Kamera
camera_none=Kamera nebyla rozpoznána
speakers=Reproduktory
speakers_none=Vestavěné reproduktory nebyly rozpoznány
mic=Mikrofon
mic_none=Vestavěný mikrofon nebyl rozpoznán
wifi_ok=Modul Wi-Fi je přítomen
wifi_none=Modul Wi-Fi nebyl rozpoznán
bt_on=zapnuto
bt_none=Řadič Bluetooth nebyl rozpoznán
s_stability=Stabilita
panics_none=V protokolech nejsou žádné kernel panic
panics=Kernel panic: %s, poslední %s
panics_hw=možný hardwarový problém
panics_hint=Protokoly mohly být smazány, takže absence pádů nezaručuje stabilitu.
therm_yes=Zaznamenáno tepelné škrcení výkonu
therm_no=Tepelné škrcení výkonu nezaznamenáno
works_q=%s — funguje správně?
checked_ok=ověřeno ručně
checked_fail=problém při ruční kontrole
kb_title=Test klávesnice.
kb_intro=Přepněte rozložení na angličtinu (US) a stiskněte každou klávesu.
kb_hint=Esc — ukončit. Modifikační klávesy (⌘ ⌥ ⌃ ⇧ fn) zkontrolujte zvlášť v libovolné aplikaci.
kb_left=Zbývá
kb_ok=Klávesnice: všechny testované klávesy fungují
kb_fail=Klávesnice: nestisknuto / nefunguje
spk_title=Test reproduktorů.
spk_intro=Zazní signál a hlas. Nastavte hlasitost na maximum a poslouchejte, zda nechrastí.
spk_name=Reproduktory
cam_title=Test kamery a mikrofonu.
cam_intro=Otevírám Photo Booth: nahrajte krátké video a přehrajte ho.
cam_name=Kamera a mikrofon
disp_title=Test displeje.
disp_intro=Otevírám v prohlížeči stránku s jednobarevnými plochami.
disp_name=Displej (bez vadných pixelů a prosvítání)
disp_html=Klikněte pro celou obrazovku.<br>Pak klik nebo mezerník — další barva. Hledejte vadné pixely, skvrny a prosvítání.<br>Esc — konec.
ask_manual=Spustit ruční testy (klávesnice, reproduktory, kamera, displej)?
s_manual=Ruční testy
s_summary=Shrnutí
verdict_fail=Zjištěny vážné problémy. Nekupujte, dokud nebudou odstraněny nebo nebude snížena cena.
verdict_warn=Žádné kritické problémy, ale projděte si varování.
verdict_ok=Všechny automatické kontroly prošly.
s_manual_check=Zkontrolujte také ručně
chk_warranty=Záruka a datum nákupu
serial_lower=sériové číslo
chk_serial=Sériové číslo v systému odpovídá číslu na spodní straně šasi
chk_diag=Apple Diagnostics: vypněte Mac a při zapínání podržte tlačítko napájení (Apple Silicon) nebo D (Intel)
chk_case=Šasi: promáčkliny, stopy po povolených šroubech, rovnost víka, vůle pantu
chk_liquid=Poškození tekutinou: skvrny na displeji, lepkavé klávesy, zkorodované porty
chk_ports=Všechny porty USB-C/Thunderbolt/HDMI/MagSafe/audio: nabíjení a přenos dat
chk_trackpad=Trackpad: klik po celé ploše, Force Touch, gesta; Touch ID; podsvícení klávesnice
chk_seller=Prodávající se musí před vámi odhlásit z Apple ID, vypnout „Najít Mac“ a Mac vymazat
chk_erase=(Nastavení → Obecné → Přenos nebo resetování → Smazat obsah a nastavení)
chk_sudo=Spuštění přes sudo přidá kontrolu konfiguračních profilů a hesla firmwaru (Intel).
report_saved=Zpráva uložena
err_macos=Tento skript funguje pouze v macOS.
help_title=kontrola stavu použitého MacBooku
help_usage=Použití: mac-check.sh [volby]
help_lang=jazyk rozhraní (výchozí: jazyk systému)
help_i=hned spustit ruční testy (klávesnice, zvuk, kamera, displej)
help_n=nenabízet ruční testy
help_o=uložit zprávu do textového souboru
help_color=bez barev
help_h=tato nápověda
help_v=verze
help_sudo=Spuštění přes sudo přidá kontrolu hesla firmwaru (Intel) a konfiguračních profilů a umožní smartctl přečíst opotřebení SSD.
EOF
}

catalog_tr() { cat <<'EOF'
collecting=Sistem verileri toplanıyor (10–30 sn)…
title=Mac durum kontrolü
s_system=Sistem
model=Model
serial=Seri numarası
cpu=İşlemci
sec_chip=Güvenlik çipi
memory=Bellek
unknown=bilinmiyor
uptime=Son açılıştan beri çalışma süresi: %s g %s sa %s dk
not_laptop=Bu bir MacBook değil (%s) — dizüstüne özel kontroller atlanacak
s_locks=Kilitler ve kayıtlar (en önemlisi!)
al_off=Etkinleştirme Kilidi kapalı
al_on=Etkinleştirme Kilidi AÇIK — bu Mac bir Apple Kimliğine bağlı
al_on_hint1=Satıcı sizin önünüzde Apple Kimliğinden çıkış yapmalı ve “Mac’imi Bul”u kapatmalı.
al_on_hint2=Aksi halde macOS yeniden yüklendikten sonra Mac başka birinin parolasını isteyecek.
fmm_on=“Mac’imi Bul” açık (NVRAM’de FMM belirteci var)
al_na=Etkinleştirme Kilidi: durum alınamıyor (T2/Apple Silicon olmayan Mac)
mdm_na=MDM: durum alınamadı
dep_yes=Mac kurumsal bir DEP/ABM’ye kayıtlı — şirket onu kilitleyebilir
dep_no=DEP / Apple Business Manager’a kayıtlı değil
mdm_yes=Mac MDM ile yönetiliyor (%s) — kurumsal bir cihaz
mdm_no=MDM ile yönetilmiyor
profiles_yes=Yüklü yapılandırma profilleri: %s (bkz. Ayarlar → Profiller)
profiles_no=Yapılandırma profili yok
fw_yes=Aygıt yazılımı (EFI) parolası ayarlı — o olmadan başka bir diskten başlatılamaz
fw_no=Aygıt yazılımı parolası yok
icloud_yes=Geçerli kullanıcı iCloud’a giriş yapmış (%s) — satıştan önce çıkış yapmalı
icloud_check=iCloud girişi: Sistem Ayarları’nın üst kısmından kontrol edin (asıl önemli olan yukarıdaki Etkinleştirme Kilidi)
sip_on=Sistem Bütünlüğü Koruması (SIP) açık
sip_off=SIP kapalı veya değiştirilmiş — sistem değiştirilmiş
fv_on=FileVault açık (sorun değil, ancak satıcı teslimden önce Mac’i silmeli)
fv_off=FileVault kapalı
s_battery=Pil ve güç
bat_missing=Pil algılanmadı — bağlantısı kesilmiş veya arızalı olabilir
cycles=Şarj döngüsü: %s / %s
cycles_over=öngörülen ömür aşıldı
cycles_worn=pil epey yıpranmış
maxcap=Maksimum kapasite
mah=%s / %s mAh
replace=Apple değiştirilmesini öneriyor
bat_cond=macOS’a göre pil durumu
bat_fake=Düşük kapasiteye rağmen çok az döngü — pil orijinal olmayan bir yedek olabilir
charge_now=Mevcut şarj
bat_serial=Pil seri numarası
ac_on=Şarj aleti bağlı
watt=W
charging=Pil şarj oluyor
ac_off=Şarj aleti bağlı değil — şarjı kontrol etmek için takın
no_battery=Pil yok (masaüstü Mac)
s_storage=Depolama
disk_none=Dahili disk algılanamadı
smart_failing=disk yakında arızalanacak!
smart_na=SMART kullanılamıyor
ssd_wear=SSD yıpranması
ssd_written=SSD’ye toplam yazılan veri
smart_sudo=smartctl yıpranma verisi döndürmedi — betiği sudo ile çalıştırın.
smart_nodata=smartctl bu disk için yıpranma verisi döndürmedi.
smart_install=SSD yıpranmasını kontrol etmek için smartmontools kurun (brew install smartmontools) ve tekrar çalıştırın.
sys_volume=Sistem birimi: %s boş / %s
s_hw=Ekran, kamera, ses, kablosuz
graphics=Grafik
cores=çekirdek
disp_int=Dahili ekran
disp_ext=Harici ekran
disp_none=Dahili ekran algılanmadı (kapak kapalı mı? veya ekran kablosu arızalı)
camera=Kamera
camera_none=Kamera algılanmadı
speakers=Hoparlörler
speakers_none=Dahili hoparlörler algılanmadı
mic=Mikrofon
mic_none=Dahili mikrofon algılanmadı
wifi_ok=Wi-Fi modülü mevcut
wifi_none=Wi-Fi modülü algılanmadı
bt_on=açık
bt_none=Bluetooth denetleyicisi algılanmadı
s_stability=Kararlılık
panics_none=Günlüklerde kernel panic yok
panics=Kernel panic: %s, sonuncusu %s
panics_hw=olası donanım sorunu
panics_hint=Günlükler silinmiş olabilir; çökme olmaması kararlılığı garanti etmez.
therm_yes=Isıl kısma kaydedildi
therm_no=Isıl kısma kaydedilmedi
works_q=%s — düzgün çalışıyor mu?
checked_ok=elle kontrol edildi
checked_fail=elle kontrolde sorun bulundu
kb_title=Klavye testi.
kb_intro=İngilizce (ABD) düzenine geçin ve her tuşa basın.
kb_hint=Bitirmek için Esc. Değiştirici tuşları (⌘ ⌥ ⌃ ⇧ fn) herhangi bir uygulamada ayrıca kontrol edin.
kb_left=Kalan
kb_ok=Klavye: test edilen tüm tuşlar çalışıyor
kb_fail=Klavye: basılmadı / çalışmıyor
spk_title=Hoparlör testi.
spk_intro=Bir sinyal ve bir ses çalınacak. Sesi sonuna kadar açın ve cızırtı olup olmadığını dinleyin.
spk_name=Hoparlörler
cam_title=Kamera ve mikrofon testi.
cam_intro=Photo Booth açılıyor: kısa bir video kaydedip oynatın.
cam_name=Kamera ve mikrofon
disp_title=Ekran testi.
disp_intro=Tarayıcıda düz renkli bir sayfa açılıyor.
disp_name=Ekran (ölü piksel ve ışık sızması olmadan)
disp_html=Tam ekran için tıklayın.<br>Sonra sonraki renk için tıklayın veya Boşluk’a basın. Ölü piksel, leke ve ışık sızmasına bakın.<br>Çıkmak için Esc.
ask_manual=Elle yapılan testler çalıştırılsın mı (klavye, hoparlörler, kamera, ekran)?
s_manual=Elle yapılan testler
s_summary=Özet
verdict_fail=Ciddi sorunlar bulundu. Giderilene veya fiyat düşene kadar satın almayın.
verdict_warn=Kritik sorun yok, ancak uyarıları inceleyin.
verdict_ok=Tüm otomatik kontroller başarılı.
s_manual_check=Ayrıca elle kontrol edin
chk_warranty=Garanti ve satın alma tarihi
serial_lower=seri numarası
chk_serial=Sistemdeki seri numarası kasanın altındakiyle aynı
chk_diag=Apple Diagnostics: Mac’i kapatın, açarken güç düğmesini (Apple Silicon) veya D’yi (Intel) basılı tutun
chk_case=Kasa: ezikler, sökülmüş vida izleri, kapak hizası, menteşe boşluğu
chk_liquid=Sıvı hasarı: ekranda lekeler, yapışkan tuşlar, oksitlenmiş bağlantı noktaları
chk_ports=Tüm USB-C/Thunderbolt/HDMI/MagSafe/ses bağlantı noktaları: şarj ve veri aktarımı
chk_trackpad=İzleme dörtgeni: tüm yüzeyde tıklama, Force Touch, hareketler; Touch ID; klavye aydınlatması
chk_seller=Satıcı sizin önünüzde Apple Kimliğinden çıkmalı, “Mac’imi Bul”u kapatmalı ve Mac’i silmeli
chk_erase=(Ayarlar → Genel → Aktar veya Sıfırla → Tüm İçeriği ve Ayarları Sil)
chk_sudo=sudo ile çalıştırmak yapılandırma profili ve aygıt yazılımı parolası (Intel) kontrollerini ekler.
report_saved=Rapor kaydedildi
err_macos=Bu betik yalnızca macOS’ta çalışır.
help_title=ikinci el MacBook için durum kontrolü
help_usage=Kullanım: mac-check.sh [seçenekler]
help_lang=arayüz dili (varsayılan: sistem dili)
help_i=elle yapılan testleri hemen başlat (klavye, ses, kamera, ekran)
help_n=elle yapılan testleri önerme
help_o=raporu bir metin dosyasına kaydet
help_color=renksiz
help_h=bu yardım
help_v=sürüm
help_sudo=sudo ile ayrıca aygıt yazılımı parolası (Intel) ve yapılandırma profilleri kontrol edilir, smartctl de SSD yıpranmasını okuyabilir.
EOF
}

main "$@"
