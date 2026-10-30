#!/bin/bash
#
# Збирає єдиний mac-check.sh із модулів src/*.sh і перекладів lang/*.txt.
# Саме зібраний файл лежить у репозиторії: його запускають через curl.
#
#   ./build.sh          перевірити переклади й зібрати mac-check.sh
#   ./build.sh --check  перевірити, що закомічений mac-check.sh актуальний

set -eu
cd "$(dirname "$0")"

OUT="mac-check.sh"

./check-lang.sh

# Мови — за іменами файлів, англійська першою (вона ж запасна).
langs="en"
for f in lang/*.txt; do
	l="$(basename "$f" .txt)"
	[ "$l" = en ] || langs="$langs $l"
done

build() {
	cat <<EOF
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
# ЗГЕНЕРОВАНИЙ ФАЙЛ — не редагуйте його напряму. Код лежить у src/*.sh,
# тексти інтерфейсу — у lang/*.txt; після змін запустіть ./build.sh.

LANGS="$langs"

# Увесь код загорнутий у main(), щоб \`curl ... | bash\` спершу прочитав скрипт
# повністю, а вже потім почав його виконувати.
main() {

EOF
	for f in src/*.sh; do
		cat "$f"
	done
	echo "}"
	echo
	echo "# ============================================================ каталоги ===="
	for l in $langs; do
		echo
		echo "catalog_$l() { cat <<'EOF'"
		cat "lang/$l.txt"
		echo "EOF"
		echo "}"
	done
	echo
	echo 'main "$@"'
}

if [ "${1:-}" = "--check" ]; then
	if build | cmp -s - "$OUT"; then
		echo "$OUT is up to date"
	else
		echo "$OUT is out of date: run ./build.sh and commit the result" >&2
		exit 1
	fi
	exit 0
fi

build > "$OUT"
chmod +x "$OUT"
bash -n "$OUT"
echo "Built $OUT ($(wc -l < "$OUT" | tr -d ' ') lines, languages: $langs)"
