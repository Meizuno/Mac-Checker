# ---------------------------------------------------------- параметри ----

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

