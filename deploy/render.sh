
#!/usr/bin/env bash
# Render deploy/templates/* per site into deploy/sites/<site>/, using
#
# CSV column names become UPPERCASE env vars. Templates reference them as
# ${VAR}. Only columns defined in the CSV header are substituted — unrelated
# shell variables (e.g. ${KUBECONFIG}, ${HERE}, bash array refs inside
# 98-px1-prepare.sh) pass through unchanged. No shell eval.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
CSV="${HERE}/sites.csv"
TEMPLATES="${HERE}/templates"
OUT="${HERE}/sites"

[ -f "$CSV" ]       || { echo "FATAL: $CSV not found"       >&2; exit 1; }
[ -d "$TEMPLATES" ] || { echo "FATAL: $TEMPLATES not found" >&2; exit 1; }

site_filter="${1:-}"

# Header row → uppercase column-name array (env-var names).
IFS=',' read -r -a headers < <(head -1 "$CSV" | tr -d '\r')
for i in "${!headers[@]}"; do
  headers[$i]="${headers[$i]^^}"
done

# Comma-joined whitelist of column names — passed to awk so substitution is
# scoped to CSV columns only.
varlist="$(IFS=,; echo "${headers[*]}")"

# ${VAR} substitution via awk, gated by the CSV-column whitelist.
subst() {
  awk -v varlist="$varlist" '
    BEGIN {
      n = split(varlist, arr, ",")
      for (i = 1; i <= n; i++) allowed[arr[i]] = 1
    }
    {
      out = ""
      while (match($0, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
        name = substr($0, RSTART+2, RLENGTH-3)
        out  = out substr($0, 1, RSTART-1)
        if ((name in allowed) && (name in ENVIRON)) {
          out = out ENVIRON[name]
        } else {
          # Leave unrelated ${VAR} tokens alone so shell scripts survive.
          out = out substr($0, RSTART, RLENGTH)
        }
        $0 = substr($0, RSTART+RLENGTH)
      }
      print out $0
    }
  '
}

declare -A seen_sites=()

tail -n +2 "$CSV" | tr -d '\r' | while IFS=',' read -r -a values; do
  [ "${#values[@]}" -gt 0 ] || continue
  [ -n "${values[0]:-}" ]   || continue   # skip blank rows

  if [ "${#values[@]}" -ne "${#headers[@]}" ]; then
    echo "FATAL: row field-count ${#values[@]} != header count ${#headers[@]}: ${values[*]}" >&2
    exit 1
  fi

  for i in "${!headers[@]}"; do
    export "${headers[$i]}=${values[$i]:-}"
  done

  site="${SITE:-}"
  [ -n "$site" ] || { echo "WARN: row has no 'site' column — skipping" >&2; continue; }
  [[ "$site" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "FATAL: unsafe site name '$site' (allowed: A-Za-z0-9_.-)" >&2; exit 1; }
  [ -z "${seen_sites[$site]:-}" ]     || { echo "FATAL: duplicate site '$site' in sites.csv" >&2; exit 1; }
  seen_sites[$site]=1

  [ -z "$site_filter" ] || [ "$site" = "$site_filter" ] || continue

  site_out="${OUT}/${site}"
  # Wipe just this site's output so other sites rendered earlier stay intact.
  rm -rf "$site_out"
  mkdir -p "$site_out"

  for template in "$TEMPLATES"/*; do
    [ -f "$template" ] || continue
    fname="$(basename "$template")"
    output="${site_out}/${fname}"
    subst < "$template" > "$output"
    # Preserve executable bit so rendered .sh scripts stay runnable.
    [ -x "$template" ] && chmod +x "$output"
    echo "[$site] rendered $output"
  done
done
