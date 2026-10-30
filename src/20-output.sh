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

