GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() { echo -e "${GREEN}→ $*${NC}"; }
log_warn() { echo -e "${YELLOW}⚠ $*${NC}" >&2; }
log_error() { echo -e "${RED}✗ $*${NC}" >&2; }
log_done() { echo -e "${GREEN}✓ $*${NC}"; }

_BUILD_LOG=$(mktemp)
trap 'rm -f "$_BUILD_LOG"' EXIT

run_quiet() {
    local label="$1"
    shift
    log_info "$label"
    if "$@" > "$_BUILD_LOG" 2>&1; then
        return 0
    else
        local rc=$?
        log_error "$label failed. Log:"
        cat "$_BUILD_LOG" >&2
        exit $rc
    fi
}
