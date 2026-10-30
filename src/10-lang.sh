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

