
#!/usr/bin/env bash
# Test connection to AWS RDS Postgres database via oltp-ro.ua-premiums.zelis.com CNAME.
# Original script exited silently when psql failed because of `set -e`. This version
# ensures we ALWAYS print a SUCCESS or FAILED message and adds better diagnostics.

set -o pipefail

usage() {
	cat <<EOF
Usage: $0 [options]

Options:
	-u USERNAME        Database user (will prompt if omitted)
	-d DBNAME          Database name (default: premiums or DB_NAME env)
	-h HOST            Database host (default: oltp-ro.ua-premiums.zelis.com or DB_HOST env)
	-p PORT            Database port (default: 5432 or DB_PORT env)
	-q QUERY           Query to run (default: SELECT 1;)
	-s SSLMODE         SSL mode (default: require) one of: disable|allow|prefer|require|verify-ca|verify-full
	-C CA_CERT_FILE    Root CA certificate file (sets PGSSLROOTCERT). Implies SSL.
	-v                 Verbose (show psql command and timing)
	-x                 Bash xtrace (debug)
	-?                 Show this help

Environment overrides: DB_HOST, DB_NAME, DB_PORT, PGSSLMODE, PGSSLROOTCERT
Default encryption: sslmode=require unless overridden.
EOF
}

VERBOSE=0
DEBUG=0
CUSTOM_QUERY=""
SSLMODE=""
CA_CERT=""

while getopts ":u:d:h:p:q:s:C:vx?" opt; do
	case $opt in
		u) DB_USER="$OPTARG" ;;
		d) DB_NAME="$OPTARG" ;;
		h) DB_HOST="$OPTARG" ;;
		p) DB_PORT="$OPTARG" ;;
		q) CUSTOM_QUERY="$OPTARG" ;;
		s) SSLMODE="$OPTARG" ;;
		C) CA_CERT="$OPTARG" ;;
		v) VERBOSE=1 ;;
		x) DEBUG=1 ;;
		?) usage; exit 0 ;;
		:) echo "Missing argument for -$OPTARG" >&2; usage; exit 2 ;;
		*) echo "Unknown option: -$OPTARG" >&2; usage; exit 2 ;;
	esac
done

shift $((OPTIND-1))

[[ $DEBUG -eq 1 ]] && set -x

DB_HOST=${DB_HOST:-oltp-ro.ua-premiums.zelis.com}
DB_NAME=${DB_NAME:-premiums}
DB_PORT=${DB_PORT:-5432}
QUERY=${CUSTOM_QUERY:-"SELECT 1;"}

if ! command -v psql >/dev/null 2>&1; then
	echo "FAILED: psql command not found in PATH" >&2
	exit 127
fi

if [[ -z "$DB_USER" ]]; then
	read -r -p "Enter database username: " DB_USER
fi

if [[ -z "$DB_PASS" ]]; then
	read -r -s -p "Enter database password: " DB_PASS
	echo
fi

export PGPASSWORD="$DB_PASS"

# Determine SSL settings. Precedence: explicit flag > env var > default (require)
if [[ -n "$SSLMODE" ]]; then
	export PGSSLMODE="$SSLMODE"
elif [[ -z "$PGSSLMODE" ]]; then
	export PGSSLMODE="require"
fi

if [[ -n "$CA_CERT" ]]; then
	if [[ ! -f "$CA_CERT" ]]; then
		echo "WARNING: CA cert file not found: $CA_CERT" >&2
	else
		export PGSSLROOTCERT="$CA_CERT"
	fi
fi

if [[ $VERBOSE -eq 1 ]]; then
	echo "SSL mode: ${PGSSLMODE}${PGSSLROOTCERT:+ (CA: $PGSSLROOTCERT)}" >&2
fi

[[ $VERBOSE -eq 1 ]] && echo "Testing connection to postgresql://$DB_HOST:$DB_PORT/$DB_NAME as $DB_USER" >&2

###############################################################################
# Cross-platform millisecond timestamp helper.
# macOS (BSD date) does not support %N, so we may get non-numeric chars if we try.
# Strategy: attempt high-res, then strip non-digits; fall back to seconds * 1000.
###############################################################################
now_millis() {
	local raw
	# Try GNU date style first (if available via coreutils as gdate) then standard date.
	if command -v gdate >/dev/null 2>&1; then
		raw=$(gdate +%s%3N 2>/dev/null)
	else
		raw=$(date +%s%3N 2>/dev/null || date +%s)
	fi
	# Keep only digits; if result length < 4 we likely only have seconds, so multiply.
	raw=${raw//[^0-9]/}
	if [[ -z "$raw" ]]; then
		raw=$(date +%s)
	fi
	# If only seconds (10 digits) make it ms by appending 000.
	if [[ ${#raw} -le 10 ]]; then
		echo "${raw}000"
	else
		echo "$raw"
	fi
}

start_ts=$(now_millis)

# Run query (quiet (-q), tuples only (-t), unaligned (-A), single transaction for speed (-1))
# ON_ERROR_STOP ensures a non-zero exit status on SQL errors.
psql_output=$(psql \
	-h "$DB_HOST" \
	-U "$DB_USER" \
	-d "$DB_NAME" \
	-p "$DB_PORT" \
	-v ON_ERROR_STOP=1 \
	-Atqc "$QUERY" 2>&1)
psql_status=$?

end_ts=$(now_millis)
elapsed_ms=$(( end_ts - start_ts ))

expected_output="1"
if [[ "$QUERY" != "SELECT 1;" ]]; then
	# If user supplied custom query we won't enforce expected output equality.
	expected_output="(custom)"
fi

success=0
if [[ $psql_status -eq 0 ]]; then
	if [[ "$QUERY" == "SELECT 1;" ]]; then
		# Trim whitespace/newlines for comparison
		trimmed="${psql_output//$'\n'/}"; trimmed="${trimmed//$'\r'/}"; trimmed=$(echo -n "$trimmed" | tr -d '[:space:]')
		if [[ "$trimmed" == "1" ]]; then
			success=1
		fi
	else
		success=1
	fi
fi

if [[ $success -eq 1 ]]; then
	echo "Database connection test: SUCCESS" 
	[[ $VERBOSE -eq 1 ]] && echo "Query output: $psql_output" && echo "Elapsed: ${elapsed_ms}ms"
	exit 0
else
	echo "Database connection test: FAILED" >&2
	echo "Exit code: $psql_status" >&2
	[[ $VERBOSE -eq 1 ]] && echo "Elapsed: ${elapsed_ms}ms" >&2
	echo "psql output:" >&2
	echo "$psql_output" >&2
	echo "Parameters: host=$DB_HOST port=$DB_PORT db=$DB_NAME user=$DB_USER query=\"$QUERY\" expected=$expected_output" >&2
	exit 1
fi

