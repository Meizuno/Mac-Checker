# -------------------------------------------- тест пам'яті та диска ----

# Тимчасовий рядок стану в терміналі, який потім стирається.
progress()      { [ -t 2 ] && printf '\r\033[K%s' "${C_DIM}$1${C_RESET}" >&2; }
progress_done() { [ -t 2 ] && printf '\r\033[K' >&2; }

# Тривалість у сотих секунди з виводу `/usr/bin/time -p` ("real 1.23" → 123), мінімум 1.
elapsed_cs() {
	local cs
	cs="$(sed -n 's/^real *\([0-9]*\)\.\([0-9]*\).*/\1\2/p' "$1" | sed 's/^0*//')"
	echo "${cs:-1}"
}

# Оцінка швидкості диска в МБ/с: для SSD усе нижче кількох сотень — підозріло.
rate_speed() {
	if [ "$2" -lt 100 ]; then
		fail "$1 — $(T disk_very_slow)"
	elif [ "$2" -lt 300 ]; then
		warn "$1 — $(T disk_slow)"
	else
		ok "$1"
	fi
}

# Базовий тест RAM: заповнює до 1 ГБ шаблонами й перевіряє, що жоден біт не змінився.
# JIT в osascript вимкнений, тож запис іде вбудованим fill(), а звірка — простим циклом.
test_memory() {
	local total_mb ram_mb res errors ms
	total_mb=$(( $(sysctl -n hw.memsize) / 1048576 ))
	ram_mb=$(( total_mb / 4 ))
	[ "$ram_mb" -gt 1024 ] && ram_mb=1024

	cat > "$TMP_DIR/memtest.js" <<'JS'
function verify(a, v) {
	var e = 0, n = a.length;
	for (var i = 0; i < n; i++) if (a[i] !== v) e++;
	return e;
}
function run(argv) {
	var n = parseInt(argv[0], 10) * 262144, t0 = Date.now(), errors = 0, a;
	try { a = new Uint32Array(n); } catch (e) { return 'ALLOC_FAIL'; }
	[0x00000000, 0xFFFFFFFF, 0xAAAAAAAA, 0x55555555].forEach(function (v) {
		a.fill(v);
		errors += verify(a, v >>> 0);
	});
	return 'OK ' + errors + ' ' + (Date.now() - t0);
}
JS
	progress "$(T ram_running "$ram_mb")"
	res="$(osascript -l JavaScript "$TMP_DIR/memtest.js" "$ram_mb" 2>/dev/null)"
	progress_done

	case "$res" in
		"OK "*)
			set -- $res
			errors="$2"; ms="$3"
			if [ "$errors" -eq 0 ]; then
				ok "$(T ram_ok "$ram_mb" "$((ms / 1000)).$((ms % 1000 / 100))")"
			else
				fail "$(T ram_fail "$errors" "$ram_mb")"
			fi ;;
		*) warn "$(T ram_alloc "$ram_mb")" ;;
	esac
	hint "$(T ram_note)"
}

# Пише 2 ГБ випадкових даних, читає їх назад і звіряє. Без root читання йде з кешу
# (purge потребує sudo), тож швидкість читання показуємо лише під sudo.
test_disk() {
	local size_mb=2048 chunk_mb=64 chunks need_mb free_mb block file wspeed rspeed block_md5 bad i
	chunks=$((size_mb / chunk_mb))
	need_mb=$((size_mb + 2048))
	free_mb="$(df -m "$TMP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')"
	if [ "${free_mb:-0}" -lt "$need_mb" ]; then
		warn "$(T disk_space $((need_mb / 1024)))"
		return
	fi

	block="$TMP_DIR/block.bin"
	file="$TMP_DIR/disktest.bin"
	head -c $((chunk_mb * 1048576)) /dev/urandom > "$block"

	progress "$(T disk_running "$size_mb")"
	/usr/bin/time -p sh -c \
		'i=0; while [ $i -lt "$2" ]; do cat "$1"; i=$((i + 1)); done > "$3"; sync' \
		sh "$block" "$chunks" "$file" 2> "$TMP_DIR/write.time"
	wspeed=$(( size_mb * 100 / $(elapsed_cs "$TMP_DIR/write.time") ))

	# Швидкість читання — чистим dd без звірки: cmp із труби дає лише ~40 МБ/с
	# і занижував би результат. Кеш скидаємо перед кожним проходом, щоб читати з диска.
	[ "$(id -u)" = 0 ] && purge 2>/dev/null
	/usr/bin/time -p dd if="$file" of=/dev/null bs=8m 2> "$TMP_DIR/read.time"
	rspeed=$(( size_mb * 100 / $(elapsed_cs "$TMP_DIR/read.time") ))

	# Звірка шматків за md5 (cmp -n на macOS ненадійний: скаржиться на EOF на однакових даних).
	[ "$(id -u)" = 0 ] && purge 2>/dev/null
	block_md5="$(md5 -q "$block")"
	bad=0
	i=0
	while [ "$i" -lt "$chunks" ]; do
		[ "$(dd if="$file" bs=1048576 skip=$((i * chunk_mb)) count="$chunk_mb" 2>/dev/null | md5 -q)" = "$block_md5" ] \
			|| bad=$((bad + 1))
		i=$((i + 1))
	done
	progress_done
	rm -f "$file" "$block"

	rate_speed "$(T disk_write "$wspeed")" "$wspeed"
	[ "$(id -u)" = 0 ] && rate_speed "$(T disk_read "$rspeed")" "$rspeed"

	if [ "$bad" -gt 0 ]; then
		fail "$(T disk_verify_fail "$bad")"
	elif [ "$(id -u)" = 0 ]; then
		ok "$(T disk_verify_ok)"
	else
		info "$(T disk_verify_cached)"
	fi
}

if [ "$STRESS" = "yes" ] || {
	[ "$STRESS" != "no" ] && [ "$INTERACTIVE" != "no" ] && has_tty && { out ""; ask_yn "$(T ask_stress)"; }
}; then
	section "$(T s_stress)"
	test_memory
	test_disk
fi

