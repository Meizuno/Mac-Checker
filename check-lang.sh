#!/bin/bash
#
# Перевіряє переклади в lang/*.txt відносно англійського lang/en.txt:
# той самий набір ключів, та сама кількість %s, жодних інших символів %
# (тексти йдуть у printf як формат) і жодного рядка "EOF" (він завершує heredoc).

set -u
cd "$(dirname "$0")"

# Ключ і кількість %s для кожного рядка "ключ=текст".
signature() {
	grep -v '^#' "$1" | grep '=' | awk -F= '{ n = gsub(/%s/, "", $0); print $1, n }'
}

status=0
for f in lang/*.txt; do
	errors=""
	if ! diff <(signature lang/en.txt) <(signature "$f") > /dev/null; then
		errors="$errors"$'\n'"  keys or %s placeholders differ from lang/en.txt:"$'\n'"$(diff <(signature lang/en.txt) <(signature "$f") | grep '^[<>]' | sed 's/^/    /')"
	fi
	bad_pct="$(sed 's/%s//g' "$f" | grep -n '%' || true)"
	[ -n "$bad_pct" ] && errors="$errors"$'\n'"  stray % (use only %s):"$'\n'"$(printf '%s\n' "$bad_pct" | sed 's/^/    line /')"
	grep -qx 'EOF' "$f" && errors="$errors"$'\n'"  contains a bare EOF line"
	bad_lines="$(grep -nv '^[a-z0-9_]*=.' "$f" | grep -v ':#' || true)"
	[ -n "$bad_lines" ] && errors="$errors"$'\n'"  lines not in key=text form:"$'\n'"$(printf '%s\n' "$bad_lines" | sed 's/^/    line /')"

	if [ -n "$errors" ]; then
		echo "$f:$errors" >&2
		status=1
	fi
done

[ "$status" = 0 ] && echo "Translations OK ($(ls lang/*.txt | wc -l | tr -d ' ') languages, $(signature lang/en.txt | wc -l | tr -d ' ') keys)"
exit "$status"
