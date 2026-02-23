#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Copyright (c) Moritz Angermann <moritz@zw3rk.com>, zw3rk pte. ltd.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ─────────────────────────────────────────────────────────────────────────────
#
# prune-immutabledb.sh — Prune old epochs from a stopped cardano-node's
# ImmutableDB to reclaim disk space.
#
# Each ImmutableDB chunk roughly corresponds to one epoch on Cardano mainnet.
# This script removes the oldest chunks (and their associated .primary and
# .secondary index files) while preserving the most recent N epochs. It also
# verifies that at least one ledger snapshot exists within the retained range
# so the node can restart without replaying from genesis.
#
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ── Colour & symbol helpers ──────────────────────────────────────────────────

readonly RED=$'\033[0;31m'
readonly GREEN=$'\033[0;32m'
readonly YELLOW=$'\033[0;33m'
readonly CYAN=$'\033[0;36m'
readonly BOLD=$'\033[1m'
readonly RESET=$'\033[0m'

info()    { printf "${CYAN}ℹ${RESET}  %s\n" "$*"; }
ok()      { printf "${GREEN}✔${RESET}  %s\n" "$*"; }
warn()    { printf "${YELLOW}⚠${RESET}  %s\n" "$*"; }
err()     { printf "${RED}✖${RESET}  %s\n" "$*" >&2; }
die()     { err "$@"; exit 1; }
section() { printf "\n${BOLD}── %s ──${RESET}\n\n" "$*"; }

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
${BOLD}prune-immutabledb.sh${RESET} — Prune old epochs from a cardano-node ImmutableDB

${BOLD}USAGE${RESET}
    $(basename "$0") --db-path PATH [OPTIONS]

${BOLD}REQUIRED${RESET}
    --db-path PATH       Path to the node's chain DB directory
                         (the directory containing immutable/, ledger/, etc.)

${BOLD}OPTIONS${RESET}
    --keep-epochs N      Number of recent epochs/chunks to keep (default: 10)
    --dry-run            Preview what would be deleted without removing anything
    --help               Show this help message

${BOLD}EXAMPLE${RESET}
    # Keep last 20 epochs, preview first:
    $(basename "$0") --db-path /opt/cardano/db --keep-epochs 20 --dry-run

    # Actually prune, keeping 10 epochs:
    $(basename "$0") --db-path /opt/cardano/db
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

DB_PATH=""
KEEP_EPOCHS=10
DRY_RUN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --db-path)
                [[ -n "${2:-}" ]] || die "--db-path requires a PATH argument"
                DB_PATH="$2"
                shift 2
                ;;
            --keep-epochs)
                [[ -n "${2:-}" ]] || die "--keep-epochs requires a numeric argument"
                [[ "$2" =~ ^[0-9]+$ ]] || die "--keep-epochs must be a positive integer, got: $2"
                KEEP_EPOCHS="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --help|-h)
                usage
                ;;
            *)
                die "Unknown argument: $1 (use --help for usage)"
                ;;
        esac
    done

    [[ -n "$DB_PATH" ]] || die "--db-path is required (use --help for usage)"
}

# ── Safety checks ────────────────────────────────────────────────────────────

# Validate that the db-path exists and looks like a cardano-node ChainDB.
validate_db_path() {
    [[ -d "$DB_PATH" ]] \
        || die "DB path does not exist or is not a directory: $DB_PATH"

    [[ -d "$DB_PATH/immutable" ]] \
        || die "No immutable/ subdirectory found in $DB_PATH — is this a cardano-node ChainDB?"
}

# Check whether cardano-node is still running against this DB. We look for:
#   1. A lock file in the DB root (ouroboros-consensus creates one while running).
#   2. Any cardano-node process whose command line references this DB path.
check_not_running() {
    local abs_db_path
    abs_db_path="$(cd "$DB_PATH" && pwd)"

    # Check for the lock file that ouroboros-consensus holds while the node runs.
    if [[ -f "$abs_db_path/lock" ]]; then
        die "Lock file found at $abs_db_path/lock — cardano-node may still be running. Stop it first."
    fi

    # Belt-and-suspenders: scan for a running cardano-node that references this path.
    if pgrep -f "cardano-node.*${abs_db_path}" >/dev/null 2>&1; then
        die "A cardano-node process appears to be using $abs_db_path. Stop it first."
    fi

    ok "No running node detected for $abs_db_path"
}

# ── Chunk discovery ──────────────────────────────────────────────────────────

# Populate the global arrays CHUNK_NUMBERS (sorted ascending, integers without
# leading zeros). We parse the 5-digit prefix from *.chunk filenames.
declare -a CHUNK_NUMBERS=()

discover_chunks() {
    local immutable_dir="$DB_PATH/immutable"
    local -a raw_chunks=()

    # Collect chunk numbers, stripping leading zeros for arithmetic.
    while IFS= read -r -d '' f; do
        local base
        base="$(basename "$f")"
        # Match XXXXX.chunk where X is a digit.
        if [[ "$base" =~ ^([0-9]{5})\.chunk$ ]]; then
            # Remove leading zeros for arithmetic (10#... forces base-10).
            raw_chunks+=("$(( 10#${BASH_REMATCH[1]} ))")
        fi
    done < <(find "$immutable_dir" -maxdepth 1 -name '*.chunk' -print0 2>/dev/null)

    if [[ ${#raw_chunks[@]} -eq 0 ]]; then
        die "No .chunk files found in $immutable_dir"
    fi

    # Sort numerically.
    IFS=$'\n' CHUNK_NUMBERS=($(sort -n <<<"${raw_chunks[*]}")); unset IFS
}

# ── Ledger snapshot validation ───────────────────────────────────────────────

# Cardano-node stores ledger snapshots in <db>/ledger/ with filenames that are
# (or encode) slot numbers. We need at least one snapshot whose slot falls
# within the retained chunk range so the node does not have to replay from
# genesis on restart.
#
# On mainnet, each epoch has ~432 000 slots (5 days × 86400 s / 1 s slot).
# We approximate the lowest retained slot as:
#     threshold_chunk × 432000
# and accept any snapshot with a slot number >= that value.

readonly SLOTS_PER_EPOCH=432000

validate_ledger_snapshots() {
    local threshold_chunk=$1
    local ledger_dir="$DB_PATH/ledger"

    if [[ ! -d "$ledger_dir" ]]; then
        warn "No ledger/ directory found — cannot verify ledger snapshot coverage."
        warn "The node may need to replay blocks from an earlier point on next start."
        return 0
    fi

    # The approximate lowest slot we are keeping.
    local min_slot=$(( threshold_chunk * SLOTS_PER_EPOCH ))

    local found=false
    local snapshot_count=0
    local kept_count=0

    for f in "$ledger_dir"/*; do
        [[ -f "$f" ]] || continue
        local name
        name="$(basename "$f")"

        # Ledger snapshot filenames are typically bare slot numbers or prefixed
        # slot numbers. Extract the largest contiguous digit sequence.
        local slot
        slot="$(grep -oE '[0-9]+' <<<"$name" | sort -rn | head -1)"
        [[ -n "$slot" ]] || continue

        snapshot_count=$(( snapshot_count + 1 ))

        if (( 10#$slot >= min_slot )); then
            kept_count=$(( kept_count + 1 ))
            found=true
        fi
    done

    if [[ "$snapshot_count" -eq 0 ]]; then
        warn "No ledger snapshots found in $ledger_dir."
        warn "The node will need to replay from genesis on next start."
        return 0
    fi

    if ! $found; then
        die "No ledger snapshot found with slot >= $min_slot (corresponding to chunk $threshold_chunk)." \
            "Pruning would leave the node unable to start without replaying from genesis." \
            "Consider using a smaller --keep-epochs value or creating a recent snapshot first."
    fi

    ok "Found $kept_count ledger snapshot(s) within the retained range (slot >= $min_slot)"
}

# ── Size estimation ──────────────────────────────────────────────────────────

# Compute total size of the files that would be deleted (in bytes).
compute_deletion_size() {
    local immutable_dir="$DB_PATH/immutable"
    local -a to_delete_chunks=("$@")
    local total_bytes=0

    for chunk_num in "${to_delete_chunks[@]}"; do
        local padded
        padded="$(printf '%05d' "$chunk_num")"
        for ext in chunk primary secondary; do
            local fpath="$immutable_dir/${padded}.${ext}"
            if [[ -f "$fpath" ]]; then
                local sz
                sz="$(stat -f%z "$fpath" 2>/dev/null || stat --printf='%s' "$fpath" 2>/dev/null || echo 0)"
                total_bytes=$(( total_bytes + sz ))
            fi
        done
    done

    echo "$total_bytes"
}

# Pretty-print a byte count in human-readable form.
human_bytes() {
    local bytes=$1
    if (( bytes >= 1073741824 )); then
        printf "%.2f GiB" "$(echo "scale=2; $bytes / 1073741824" | bc)"
    elif (( bytes >= 1048576 )); then
        printf "%.2f MiB" "$(echo "scale=2; $bytes / 1048576" | bc)"
    elif (( bytes >= 1024 )); then
        printf "%.2f KiB" "$(echo "scale=2; $bytes / 1024" | bc)"
    else
        printf "%d B" "$bytes"
    fi
}

# ── Deletion ─────────────────────────────────────────────────────────────────

# Delete the .chunk, .primary, and .secondary files for the given chunk numbers.
delete_chunks() {
    local immutable_dir="$DB_PATH/immutable"
    local -a to_delete_chunks=("$@")
    local deleted=0

    for chunk_num in "${to_delete_chunks[@]}"; do
        local padded
        padded="$(printf '%05d' "$chunk_num")"
        for ext in chunk primary secondary; do
            local fpath="$immutable_dir/${padded}.${ext}"
            if [[ -f "$fpath" ]]; then
                rm -f "$fpath"
                deleted=$(( deleted + 1 ))
            fi
        done
    done

    ok "Removed $deleted files across ${#to_delete_chunks[@]} chunks"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    section "Safety checks"
    validate_db_path
    check_not_running

    section "Discovering chunks"
    discover_chunks

    local lowest=${CHUNK_NUMBERS[0]}
    local highest=${CHUNK_NUMBERS[${#CHUNK_NUMBERS[@]}-1]}
    local total=${#CHUNK_NUMBERS[@]}

    info "Chunk range : $lowest … $highest  ($total chunks)"

    # Compute the threshold: chunks strictly below this number will be pruned.
    local threshold=$(( highest - KEEP_EPOCHS ))

    if (( threshold <= lowest )); then
        ok "Nothing to prune — all $total chunks fall within the --keep-epochs=$KEEP_EPOCHS window."
        exit 0
    fi

    # Build the list of chunks to delete (those below the threshold).
    local -a to_delete=()
    local -a to_keep=()
    for c in "${CHUNK_NUMBERS[@]}"; do
        if (( c < threshold )); then
            to_delete+=("$c")
        else
            to_keep+=("$c")
        fi
    done

    section "Pruning plan"
    info "Keeping      : ${#to_keep[@]} chunks  ($threshold … $highest)"
    info "Deleting     : ${#to_delete[@]} chunks  ($lowest … $(( threshold - 1 )))"

    local freed_bytes
    freed_bytes="$(compute_deletion_size "${to_delete[@]}")"
    info "Estimated freed space : $(human_bytes "$freed_bytes")"

    section "Ledger snapshot check"
    validate_ledger_snapshots "$threshold"

    # ── Execute or preview ───────────────────────────────────────────────────

    if $DRY_RUN; then
        section "Dry-run mode — no files will be deleted"
        info "Files that would be removed:"
        for c in "${to_delete[@]}"; do
            local padded
            padded="$(printf '%05d' "$c")"
            for ext in chunk primary secondary; do
                local fpath="$DB_PATH/immutable/${padded}.${ext}"
                [[ -f "$fpath" ]] && printf "  ${RED}−${RESET} %s\n" "$fpath"
            done
        done
        echo ""
        warn "Re-run without --dry-run to actually delete these files."
    else
        section "Pruning"
        delete_chunks "${to_delete[@]}"
        info "Estimated space freed : $(human_bytes "$freed_bytes")"
        ok "Done. ImmutableDB now spans chunks $threshold … $highest."
    fi
}

main "$@"
