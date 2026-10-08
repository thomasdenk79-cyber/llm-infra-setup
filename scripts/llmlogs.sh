#!/usr/bin/env bash
# Follow systemd and Podman logs for local models, gateways, and agents.
set -Eeuo pipefail

units=(pennyroyal litellm litellm-postgres open-webui bonsai hermes hermes-gateway)
fork_container=flash-next-sm120
forge_dir="${FORGE_DIR:-$HOME/forge}"
fork_artifacts="${forge_dir}/fork/artifacts/sm120"
lines=100
since=1h
follow=1
selected=()
extras=()      # non-journal sources: fork, fork-last, reference-start, guard
explicit=0

usage() {
  cat <<'EOF'
Usage: llmlogs [--no-follow] [--lines N] [--since DURATION] [--fork-last] [UNIT|SOURCE...]

Default: follow recent journal entries for the LLM/agent systemd services
and, if it exists, the SGLang test-fork container flash-next-sm120 (podman
logs; only present during GPU windows).
Journald applies native severity colors in an interactive terminal; set
NO_COLOR to disable. Press Ctrl-C to stop.

Extra SOURCEs (besides systemd units):
  fork             podman logs of flash-next-sm120; if the container is gone,
                   falls back to the newest candidate.log
  fork-last        newest ~/forge/fork/artifacts/sm120/*/candidate.log (no follow)
  reference-start  ~/forge/logs/reference-start.log
  guard            ~/forge/logs/guard.log
  (--fork-last is an alias for the SOURCE fork-last; FORGE_DIR overrides ~/forge)
Examples:
  llmlogs
  llmlogs pennyroyal litellm
  llmlogs --since 30m --lines 300
  llmlogs --no-follow --since 10m pennyroyal
  llmlogs fork
  llmlogs --fork-last --lines 300
  llmlogs pennyroyal fork guard reference-start
EOF
}

while (($#)); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    -f|--follow) follow=1 ;;
    --no-follow) follow=0 ;;
    --fork-last) selected+=(fork-last) ;;
    -n|--lines) (($# >= 2)) || { echo 'Missing value for --lines' >&2; exit 2; }; lines="$2"; shift ;;
    -S|--since) (($# >= 2)) || { echo 'Missing value for --since' >&2; exit 2; }; since="$2"; shift ;;
    --) shift; selected+=("$@"); break ;;
    -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) selected+=("$1") ;;
  esac
  shift
done

[[ "$lines" =~ ^[1-9][0-9]*$ ]] || { echo '--lines must be a positive integer' >&2; exit 2; }

fork_exists() {
  command -v podman >/dev/null 2>&1 && podman container exists "$fork_container" 2>/dev/null
}

if ((${#selected[@]})); then
  explicit=1
  sel=()
  for s in "${selected[@]}"; do
    case "$s" in
      fork|"$fork_container") extras+=(fork) ;;
      fork-last|reference-start|guard) extras+=("$s") ;;
      *) sel+=("$s") ;;
    esac
  done
  selected=("${sel[@]}")
else
  selected=("${units[@]}")
  fork_exists && extras+=(fork)
fi

journal_since="$since"
if [[ "$since" =~ ^([0-9]+)(s|m|h|d)$ ]]; then
  amount="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    s) unit=second ;; m) unit=minute ;; h) unit=hour ;; d) unit=day ;;
  esac
  ((amount == 1)) || unit+="s"
  journal_since="$amount $unit ago"
fi

color=auto
if [[ ! -t 1 || -n "${NO_COLOR:-}" || "${TERM:-dumb}" == dumb ]]; then
  color=no
fi

run_journal() {
  local journal_args=() journal_tail=() unit
  for unit in "${selected[@]}"; do
    journal_args+=(-u "${unit}.service")
  done
  ((follow)) && journal_tail=(-f)
  if [[ "$color" == no ]]; then
    SYSTEMD_COLORS=0 journalctl --user --no-pager --since "$journal_since" -n "$lines" \
      -o short "${journal_args[@]}" "${journal_tail[@]}"
  else
    journalctl --user --no-pager --since "$journal_since" -n "$lines" \
      -o short "${journal_args[@]}" "${journal_tail[@]}"
  fi
}

newest_candidate_log() {
  local f
  # newest by mtime
  f="$(ls -t "$fork_artifacts"/*/candidate.log 2>/dev/null | head -n 1 || true)"
  [[ -n "$f" ]] && printf '%s\n' "$f"
}

show_file() { # file follow(0|1)
  local f="$1" fol="$2"
  if [[ ! -r "$f" ]]; then
    echo "Datei nicht gefunden: $f" >&2
    return 1
  fi
  echo "==> $f <==" >&2
  if ((fol)); then tail -n "$lines" -F "$f"; else tail -n "$lines" "$f"; fi
}

show_fork_last() {
  local f
  f="$(newest_candidate_log || true)"
  if [[ -z "$f" ]]; then
    echo "Kein candidate.log unter $fork_artifacts gefunden." >&2
    return 1
  fi
  show_file "$f" 0
}

run_extra() { # name
  case "$1" in
    fork)
      if fork_exists; then
        local fol=()
        ((follow)) && fol=(-f)
        echo "==> podman logs $fork_container <==" >&2
        podman logs --since "$since" --tail "$lines" "${fol[@]}" "$fork_container" 2>&1
      else
        echo "Container $fork_container existiert nicht (kein GPU-Fenster aktiv) - zeige neuestes candidate.log." >&2
        show_fork_last
      fi ;;
    fork-last) show_fork_last ;;
    reference-start) show_file "$forge_dir/logs/reference-start.log" "$follow" ;;
    guard) show_file "$forge_dir/logs/guard.log" "$follow" ;;
  esac
}

# De-duplicate extras, keep order.
uniq_extras=()
for e in "${extras[@]}"; do
  [[ " ${uniq_extras[*]-} " == *" $e "* ]] || uniq_extras+=("$e")
done
extras=("${uniq_extras[@]}")

have_journal=1
((explicit && ${#selected[@]} == 0)) && have_journal=0

# Only one source: run it directly (original behavior for journal-only).
if ((have_journal && ${#extras[@]} == 0)); then
  run_journal
  exit $?
fi
if ((!have_journal && ${#extras[@]} == 1)); then
  run_extra "${extras[0]}"
  exit $?
fi

# Several sources: run in parallel (follow) or one after another (no follow).
if ((follow)); then
  pids=()
  trap 'kill "${pids[@]}" 2>/dev/null || true' INT TERM EXIT
  if ((have_journal)); then run_journal & pids+=($!); fi
  for e in "${extras[@]}"; do
    # fork-last is static; run it inline so it is printed first, not interleaved
    run_extra "$e" & pids+=($!)
  done
  wait || true
else
  rc=0
  if ((have_journal)); then run_journal || rc=$?; fi
  for e in "${extras[@]}"; do
    echo "--- $e ---" >&2
    run_extra "$e" || rc=$?
  done
  exit "$rc"
fi