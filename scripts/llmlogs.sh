#!/usr/bin/env bash
# Follow systemd and Podman logs for local models, gateways, and agents.
set -Eeuo pipefail

units=(pennyroyal litellm litellm-postgres open-webui bonsai hermes hermes-gateway)
lines=100
since=1h
follow=1
selected=()

usage() {
  cat <<'EOF'
Usage: llmlogs [--no-follow] [--lines N] [--since DURATION] [UNIT...]

Default: follow recent journal entries for the LLM/agent systemd services.
Journald applies native severity colors in an interactive terminal; set
NO_COLOR to disable. Press Ctrl-C to stop.
Examples:
  llmlogs
  llmlogs pennyroyal litellm
  llmlogs --since 30m --lines 300
  llmlogs --no-follow --since 10m pennyroyal
EOF
}

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -f|--follow) follow=1 ;;
    --no-follow) follow=0 ;;
    -n|--lines) (($# >= 2)) || { echo 'Missing value for --lines' >&2; exit 2; }; lines="$2"; shift ;;
    -S|--since) (($# >= 2)) || { echo 'Missing value for --since' >&2; exit 2; }; since="$2"; shift ;;
    --) shift; selected+=("$@"); break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) selected+=("$1") ;;
  esac
  shift
done

[[ "$lines" =~ ^[1-9][0-9]*$ ]] || { echo '--lines must be a positive integer' >&2; exit 2; }
((${#selected[@]})) || selected=("${units[@]}")

journal_since="$since"
if [[ "$since" =~ ^([0-9]+)(s|m|h|d)$ ]]; then
  amount="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    s) unit=second ;; m) unit=minute ;; h) unit=hour ;; d) unit=day ;;
  esac
  ((amount == 1)) || unit+="s"
  journal_since="$amount $unit ago"
fi

journal_args=()
for unit in "${selected[@]}"; do
  journal_args+=(-u "${unit}.service")
done
journal_tail=()
color=auto
if [[ ! -t 1 || -n "${NO_COLOR:-}" || "${TERM:-dumb}" == dumb ]]; then
  color=no
fi
((follow)) && journal_tail=(-f)

if [[ "$color" == no ]]; then
  SYSTEMD_COLORS=0 journalctl --user --no-pager --since "$journal_since" -n "$lines" \
    -o short "${journal_args[@]}" "${journal_tail[@]}"
else
  journalctl --user --no-pager --since "$journal_since" -n "$lines" \
    -o short "${journal_args[@]}" "${journal_tail[@]}"
fi