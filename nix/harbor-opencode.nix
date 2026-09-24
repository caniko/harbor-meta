{
  pkgs,
  lib,
}: let
  markerKey = lib.opencode.formatPolicy.marker;
  render = kind: openpencil:
    lib.opencode.configTextFor {
      inherit kind openpencil;
    };
  script = ''
    set -euo pipefail

    usage() {
      cat <<'USAGE'
    Usage:
      harbor-opencode sync --kind rust|python|mixed|none|detect [--openpencil] [--force] [--root DIR]
      harbor-opencode check --kind rust|python|mixed|none|detect [--openpencil] [--root DIR]
      harbor-opencode detect [--root DIR]
      harbor-opencode rollout [--root DIR] [--check] [--force]

    rollout treats every git repository under --root as a project; kind
    detection is language-independent and falls back to `none` (a
    policy-only config). Dirty working trees are coordination-blocked and
    reported separately; --check inspects their config state read-only. A
    config that lacks the '${markerKey}' marker is treated as hand-written
    and is never overwritten without --force.
    USAGE
    }

    die() {
      printf 'harbor-opencode: %s\n' "$*" >&2
      exit 1
    }

    root="."
    kind="detect"
    check_only=0
    openpencil=0
    force=0

    parse_common() {
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --kind)
            [ "$#" -ge 2 ] || die "--kind requires a value"
            kind="$2"
            shift 2
            ;;
          --root)
            [ "$#" -ge 2 ] || die "--root requires a value"
            root="$2"
            shift 2
            ;;
          --openpencil)
            openpencil=1
            shift
            ;;
          --force)
            force=1
            shift
            ;;
          --check)
            check_only=1
            shift
            ;;
          -h|--help)
            usage
            exit 0
            ;;
          *)
            die "unknown argument: $1"
            ;;
        esac
      done
    }

    detect_kind() {
      local dir="$1"
      local has_rust=0
      local has_python=0

      [ -f "$dir/Cargo.toml" ] && has_rust=1
      [ -f "$dir/pyproject.toml" ] && has_python=1

      if [ -f "$dir/flake.nix" ]; then
        grep -Eq 'harbor-rs|rs-harbor|mkDevShell|mkDevShells' "$dir/flake.nix" && has_rust=1
        grep -Eq 'harbor-py|py-harbor|mkUvDevShell|mkUvDevShells' "$dir/flake.nix" && has_python=1
      fi

      if [ "$has_rust" -eq 1 ] && [ "$has_python" -eq 1 ]; then
        printf 'mixed\n'
      elif [ "$has_rust" -eq 1 ]; then
        printf 'rust\n'
      elif [ "$has_python" -eq 1 ]; then
        printf 'python\n'
      else
        # Language-independent fallback: a project that exposes no Rust or
        # Python surface still gets the formatter policy (policy-only kind).
        printf 'none\n'
      fi
    }

    resolve_kind() {
      local dir="$1"
      case "$kind" in
        detect) detect_kind "$dir" ;;
        rust|python|mixed|none) printf '%s\n' "$kind" ;;
        *) die "unsupported kind: $kind" ;;
      esac
    }

    extra_flags() {
      if [ "$openpencil" -eq 1 ]; then
        printf ' --openpencil'
      fi
    }

    label() {
      if [ "$openpencil" -eq 1 ]; then
        printf '%s+openpencil\n' "$1"
      else
        printf '%s\n' "$1"
      fi
    }

    render_config() {
      # shellcheck disable=SC2016 # JSON literals below contain intentional $ kept verbatim.
      case "$1:$openpencil" in
        rust:0) printf '%s' '${render "rust" false}' ;;
        rust:1) printf '%s' '${render "rust" true}' ;;
        python:0) printf '%s' '${render "python" false}' ;;
        python:1) printf '%s' '${render "python" true}' ;;
        mixed:0) printf '%s' '${render "mixed" false}' ;;
        mixed:1) printf '%s' '${render "mixed" true}' ;;
        none:0) printf '%s' '${render "none" false}' ;;
        none:1) printf '%s' '${render "none" true}' ;;
        *) die "unsupported kind: $1" ;;
      esac
    }

    config_path() {
      printf '%s/.opencode/opencode.jsonc\n' "$1"
    }

    marker_key='${markerKey}'

    # Classify the config under a project dir:
    #   missing | ok | stale | custom
    # `custom` means the file does not match our render AND lacks the
    # harbor marker, i.e. it was hand-written and must not be clobbered
    # without --force. A differing file that carries the marker is merely
    # `stale` (an older harbor render) and is safe to overwrite.
    config_state() {
      local dir="$1"
      local path tmp resolved
      path="$(config_path "$dir")"
      [ -f "$path" ] || {
        printf 'missing\n'
        return 0
      }
      resolved="$(resolve_kind "$dir")"
      tmp="$(mktemp)"
      render_config "$resolved" > "$tmp"
      if diff -q "$tmp" "$path" >/dev/null 2>&1; then
        printf 'ok\n'
      elif ! grep -qF "$marker_key" "$path"; then
        printf 'custom\n'
      else
        printf 'stale\n'
      fi
      rm -f "$tmp"
    }

    # Coordination-blocked only for changes the tool does not own: the
    # rendered config sitting uncommitted between rollout and the operator's
    # commit is expected dirt, everything else belongs to another session.
    foreign_dirty() {
      local dir="$1"
      local line stripped
      [ -e "$dir/.git" ] || return 1
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        stripped="''${line:3}"
        case "$stripped" in
          ".opencode/opencode.jsonc") ;;
          *) return 0 ;;
        esac
      done <<< "$(git -C "$dir" status --porcelain 2>/dev/null || true)"
      return 1
    }

    sync_one() {
      local dir="$1"
      local resolved path state
      resolved="$(resolve_kind "$dir")"
      path="$(config_path "$dir")"
      state="$(config_state "$dir")"
      if [ "$state" = "custom" ] && [ "$force" -eq 0 ]; then
        printf '%s: %s is a custom config (missing %s marker); refusing to replace it — rerun with --force to overwrite\n' \
          "$dir" "$path" "$marker_key" >&2
        return 1
      fi
      mkdir -p "$(dirname "$path")"
      render_config "$resolved" > "$path"
      printf '%s: synced %s\n' "$dir" "$(label "$resolved")"
    }

    check_one() {
      local dir="$1"
      local resolved path state
      resolved="$(resolve_kind "$dir")"
      path="$(config_path "$dir")"
      state="$(config_state "$dir")"
      case "$state" in
        ok)
          printf '%s: ok %s\n' "$dir" "$(label "$resolved")"
          ;;
        missing)
          printf '%s: %s is missing; run harbor-opencode sync --kind %s%s --root %s\n' \
            "$dir" "$path" "$resolved" "$(extra_flags)" "$dir" >&2
          return 1
          ;;
        stale)
          printf '%s: %s is stale; run harbor-opencode sync --kind %s%s --root %s\n' \
            "$dir" "$path" "$resolved" "$(extra_flags)" "$dir" >&2
          return 1
          ;;
        custom)
          printf '%s: %s is a custom config (missing %s marker) and does not match the harbor render; review it, then replace it with sync --force\n' \
            "$dir" "$path" "$marker_key" >&2
          return 1
          ;;
      esac
    }

    rollout() {
      local scan_root="$1"
      local total=0 ok=0 synced=0 unchanged=0 stale=0 missing=0 custom=0 blocked=0 dirty=0
      local dir path state resolved dirty_note
      local -a dirs=()

      # Every git repository under the scan root is a project: formatter
      # policy generation is language-independent, so kind detection falls
      # back to `none` (policy-only config) instead of skipping repos.
      while IFS= read -r git_entry; do
        dirs+=("$(dirname "$git_entry")")
      done < <(find "$scan_root" -mindepth 1 -maxdepth 3 -name .git -print | sort)

      [ "''${#dirs[@]}" -gt 0 ] || die "no git repositories found under $scan_root"

      for dir in "''${dirs[@]}"; do
        total=$((total + 1))
        path="$(config_path "$dir")"
        dirty_note=""
        if foreign_dirty "$dir"; then
          dirty=$((dirty + 1))
          dirty_note=" (dirty)"
          if [ "$check_only" -eq 0 ]; then
            # Coordination-blocked: reported separately, never permanently
            # excluded — the next rollout picks the repo up once it is clean.
            blocked=$((blocked + 1))
            printf '%s: blocked (dirty working tree)\n' "$dir" >&2
            continue
          fi
        fi

        state="$(config_state "$dir")"
        if [ "$check_only" -eq 1 ]; then
          case "$state" in
            ok)
              ok=$((ok + 1))
              printf '%s: ok%s\n' "$dir" "$dirty_note"
              ;;
            stale)
              stale=$((stale + 1))
              printf '%s: stale%s\n' "$dir" "$dirty_note" >&2
              ;;
            missing)
              missing=$((missing + 1))
              printf '%s: missing%s\n' "$dir" "$dirty_note" >&2
              ;;
            custom)
              custom=$((custom + 1))
              printf '%s: custom config (missing %s marker)%s\n' "$dir" "$marker_key" "$dirty_note" >&2
              ;;
          esac
        else
          if [ "$state" = "custom" ] && [ "$force" -eq 0 ]; then
            custom=$((custom + 1))
            printf '%s: custom config (missing %s marker); skipped, rerun with --force to overwrite\n' \
              "$dir" "$marker_key" >&2
            continue
          fi
          resolved="$(resolve_kind "$dir")"
          mkdir -p "$(dirname "$path")"
          render_config "$resolved" > "$path"
          if [ "$state" = "ok" ]; then
            unchanged=$((unchanged + 1))
          else
            synced=$((synced + 1))
          fi
          printf '%s: synced %s%s\n' "$dir" "$(label "$resolved")" "$dirty_note"
        fi
      done

      if [ "$check_only" -eq 1 ]; then
        printf 'harbor-opencode rollout: total=%d ok=%d stale=%d missing=%d custom=%d dirty=%d\n' \
          "$total" "$ok" "$stale" "$missing" "$custom" "$dirty"
        [ $((stale + missing + custom)) -eq 0 ] || exit 1
      else
        printf 'harbor-opencode rollout: total=%d synced=%d unchanged=%d blocked-dirty=%d custom=%d dirty=%d\n' \
          "$total" "$synced" "$unchanged" "$blocked" "$custom" "$dirty"
        [ $((blocked + custom)) -eq 0 ] || exit 1
      fi
    }

    [ "$#" -ge 1 ] || {
      usage
      exit 2
    }

    cmd="$1"
    shift

    case "$cmd" in
      sync)
        parse_common "$@"
        sync_one "$root"
        ;;
      check)
        parse_common "$@"
        check_one "$root"
        ;;
      detect)
        parse_common "$@"
        detect_kind "$root"
        ;;
      rollout)
        parse_common "$@"
        rollout "$root"
        ;;
      -h|--help)
        usage
        ;;
      *)
        die "unknown command: $cmd"
        ;;
    esac
  '';
in
  pkgs.writeShellApplication {
    name = "harbor-opencode";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.git
    ];
    text = script;
  }
