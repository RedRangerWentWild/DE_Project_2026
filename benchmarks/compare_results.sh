#!/usr/bin/env bash
# Proves that the optimized workload returns the same results as the original one.
#
# Usage:   ./benchmarks/compare_results.sh <before_db> <after_db> [original.sql] [optimized.sql]
# Example: ./benchmarks/compare_results.sh practo_base practo
#
#   before_db  the database in its Phase 3 state (no sql/05_indexes.sql)
#   after_db   the same data with sql/05_indexes.sql applied
#   The ORIGINAL queries run on before_db and the OPTIMIZED queries on after_db,
#   i.e. exactly "before" and "after" as a user would see them.
#
# For every READ query it prints:
#   rows      number of rows returned by the original / optimized query
#   set       md5 of the rows sorted as text -> same set of rows, order ignored
#   keys      md5 of only the ORDER BY columns, in the order the query returned
#             them -> the order is the same up to rows whose sort keys are equal
#             (which the ORDER BY leaves undefined)
# For every WRITE query (run inside BEGIN ... ROLLBACK, data never changes):
#   rows      number of rows the statement changed
#   set       md5 of every changed row after the change (found via xmin = the
#             current transaction), so it also proves WHICH rows changed and how
#
# Verdicts: IDENTICAL (same rows, same order), SAME (same rows; order differs
# only among rows with equal sort keys), TIES (same count and same sort keys, but
# a different row was chosen among rows that tie at a LIMIT/OFFSET boundary),
# DIFFERENT (anything else - must be explained).
set -euo pipefail

BEFORE="${1:?before_db required}"
AFTER="${2:?after_db required}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ORIG="${3:-$ROOT/queries/workload_30.sql}"
OPT="${4:-$ROOT/sql/06_optimized_queries.sql}"
die() { echo "compare_results.sh: $*" >&2; exit 2; }
[[ -r "$ORIG" ]] || die "cannot read $ORIG"
[[ -r "$OPT" ]] || die "cannot read $OPT"
for db in "$BEFORE" "$AFTER"; do
  state="$(psql -d "$db" -X -q -A -t -c "SELECT to_regclass('practo.appointments') IS NOT NULL" 2>&1)" \
    || die "cannot connect to database '$db': $state"
  [[ "$state" == t ]] || die "database '$db' has no practo schema: load sql/01_schema.sql and sql/02_load_data.sql first"
done

# ORDER BY columns of each query, as positions in its output (cut -f syntax)
declare -A KEYS=(
  [R01]=3 [R02]=1,2 [R03]=1 [R04]=4 [R05]=3 [R06]= [R07]=3 [R08]=3 [R09]=3 [R10]=5
  [R11]=4 [R12]=1,2 [R13]= [R14]=2,4 [R15]=1,3 [R16]=4 [R17]=1,2 [R18]=4 [R19]=3 [R20]=1
  [R21]=5 [R22]=5 [R23]= [R24]=2 [R25]=3,1
)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
split() {  # same splitting rule as run_benchmark.sh
  awk -v dir="$2" '
    /^-- @/ { id = ""; if ($2 ~ /^@[RW][0-9]+$/) { id = substr($2, 2); file = dir "/" id ".sql"; printf "" > file }; next }
    id != "" && !/^--/ { print >> file }
  ' "$1"
}
mkdir -p "$TMP/orig" "$TMP/opt"
split "$ORIG" "$TMP/orig"
split "$OPT" "$TMP/opt"

md5() { md5sum | cut -c1-12; }

run_read() {  # db file -> rows on stdout, '|'-separated
  { echo "SET search_path TO practo;"; cat "$2"; } | psql -d "$1" -X -q -A -t -F '|' -v ON_ERROR_STOP=1
}

run_write() {  # db file -> "<rows changed> <md5 of changed rows>"
  local table
  table="$(grep -oiE '^(UPDATE|INSERT INTO)[[:space:]]+[a-z_]+' "$2" | head -1 | awk '{print $NF}')"
  { echo "SET search_path TO practo; BEGIN;"
    cat "$2"
    echo "SELECT count(*) || ' ' || coalesce(md5(string_agg(t::text, E'\\n' ORDER BY t::text)), '-')
          FROM $table t WHERE t.xmin::text = (txid_current() % 4294967296)::text;"
    echo "ROLLBACK;"
  } | psql -d "$1" -X -q -A -t -v ON_ERROR_STOP=1 | tail -1 | awk '{print $1, substr($2, 1, 12)}'
}

printf '%-4s %-5s %9s %9s  %-12s %-12s %-12s %-12s  %s\n' query type rows_orig rows_opt set_orig set_opt keys_orig keys_opt verdict
for f in $(ls "$TMP/orig"/*.sql | sort -V); do
  id="$(basename "$f" .sql)"
  [[ -f "$TMP/opt/$id.sql" ]] || die "$id is in $ORIG but not in $OPT"
  if [[ "$id" == W* ]]; then
    # assigned first: a failure inside "read <<< $(...)" would go unnoticed,
    # and two failures would compare equal and be reported as IDENTICAL
    r1="$(run_write "$BEFORE" "$f")" || die "$id failed on $BEFORE"
    r2="$(run_write "$AFTER" "$TMP/opt/$id.sql")" || die "$id failed on $AFTER"
    read -r n1 s1 <<< "$r1"
    read -r n2 s2 <<< "$r2"
    k1=-; k2=-
    if [[ "$n1" == "$n2" && "$s1" == "$s2" ]]; then v=IDENTICAL; else v=DIFFERENT; fi
    type=WRITE
  else
    run_read "$BEFORE" "$f" > "$TMP/$id.orig" || die "$id failed on $BEFORE"
    run_read "$AFTER" "$TMP/opt/$id.sql" > "$TMP/$id.opt" || die "$id failed on $AFTER"
    n1=$(wc -l < "$TMP/$id.orig"); n2=$(wc -l < "$TMP/$id.opt")
    s1=$(sort "$TMP/$id.orig" | md5); s2=$(sort "$TMP/$id.opt" | md5)
    o1=$(md5 < "$TMP/$id.orig"); o2=$(md5 < "$TMP/$id.opt")
    if [[ -n "${KEYS[$id]}" ]]; then
      k1=$(cut -d'|' -f"${KEYS[$id]}" "$TMP/$id.orig" | md5); k2=$(cut -d'|' -f"${KEYS[$id]}" "$TMP/$id.opt" | md5)
    else
      k1=-; k2=-
    fi
    if [[ "$n1" == "$n2" && "$o1" == "$o2" ]]; then v=IDENTICAL
    elif [[ "$n1" == "$n2" && "$s1" == "$s2" && "$k1" == "$k2" ]]; then v=SAME
    elif [[ "$n1" == "$n2" && "$k1" != "-" && "$k1" == "$k2" ]]; then v=TIES
    else v=DIFFERENT; fi
    type=READ
  fi
  printf '%-4s %-5s %9s %9s  %-12s %-12s %-12s %-12s  %s\n' "$id" "$type" "$n1" "$n2" "$s1" "$s2" "$k1" "$k2" "$v"
done
