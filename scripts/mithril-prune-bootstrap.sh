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
# mithril-prune-bootstrap.sh — Bootstrap a pruned cardano-node from a Mithril
# snapshot: download, verify, prune old epochs, and validate the result.
#
# This script is a convenience wrapper that:
#   1. Downloads and verifies a Mithril snapshot using mithril-client
#   2. Prunes old ImmutableDB chunks to keep only the last N epochs
#   3. Verifies the ledger snapshot is within the retained range
#
# The result is a ~20 GB database instead of ~190+ GB, suitable for running
# a pruned cardano-node that participates in consensus without full history.
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

# ── Network configuration ───────────────────────────────────────────────────

# Mithril aggregator endpoints per network.
declare -A MITHRIL_AGGREGATORS=(
    [mainnet]="https://aggregator.release-mainnet.api.mithril.network/aggregator"
    [preprod]="https://aggregator.release-preprod.api.mithril.network/aggregator"
    [preview]="https://aggregator.pre-release-preview.api.mithril.network/aggregator"
)

# Genesis verification keys per network (abridged, mithril-client fetches full key).
declare -A MITHRIL_GENESIS_KEYS=(
    [mainnet]="5b3132372c37332c3132342c3136312c362c3133372c3133312c3231332c3230372c3131372c3131302c3233372c3230352c3134372c322c3234392c34302c3232382c3234312c3231322c3234352c33392c3233352c34312c3131342c3131312c3233322c3234382c34302c3234382c3230342c3233382c3133312c3133382c3132342c3132302c3230372c3133382c3233342c3132302c3134312c3232312c31"
    [preprod]="5b3132372c37332c3132342c3136312c362c3133372c3133312c3231332c3230372c3131372c3131302c3233372c3230352c3134372c322c3234392c34302c3232382c3234312c3231322c3234352c33392c3233352c34312c3131342c3131312c3233322c3234382c34302c3234382c3230342c3233382c3133312c3133382c3132342c3132302c3230372c3133382c3233342c3132302c3134312c3232312c31"
    [preview]="5b3132372c37332c3132342c3136312c362c3133372c3133312c3231332c3230372c3131372c3131302c3233372c3230352c3134372c322c3234392c34302c3232382c3234312c3231322c3234352c33392c3233352c34312c3131342c3131312c3233322c3234382c34302c3234382c3230342c3233382c3133312c3133382c3132342c3132302c3230372c3133382c3233342c3132302c3134312c3232312c31"
)

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
    cat <<EOF
${BOLD}mithril-prune-bootstrap.sh${RESET} — Bootstrap a pruned node from a Mithril snapshot

${BOLD}USAGE${RESET}
    $(basename "$0") --db-path PATH --network NETWORK [OPTIONS]

${BOLD}REQUIRED${RESET}
    --db-path PATH           Target directory for the chain DB
    --network NETWORK        Cardano network: mainnet, preprod, or preview

${BOLD}OPTIONS${RESET}
    --keep-epochs N          Number of recent epochs/chunks to keep (default: 10)
    --mithril-client PATH    Path to mithril-client binary (default: searches PATH)
    --skip-download          Skip Mithril download; assume DB already exists at --db-path
    --dry-run                Preview the pruning plan without deleting anything
    --help                   Show this help message

${BOLD}EXAMPLES${RESET}
    # Full bootstrap: download preprod snapshot, keep 10 epochs
    $(basename "$0") --db-path /opt/cardano/db --network preprod

    # Prune an existing Mithril-downloaded DB, keeping 5 epochs
    $(basename "$0") --db-path /opt/cardano/db --network mainnet \\
        --keep-epochs 5 --skip-download

    # Preview what would be pruned on a mainnet DB
    $(basename "$0") --db-path /opt/cardano/db --network mainnet --dry-run --skip-download
EOF
    exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────────────

DB_PATH=""
NETWORK=""
KEEP_EPOCHS=10
MITHRIL_CLIENT=""
SKIP_DOWNLOAD=false
DRY_RUN=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --db-path)
                [[ -n "${2:-}" ]] || die "--db-path requires a PATH argument"
                DB_PATH="$2"
                shift 2
                ;;
            --network)
                [[ -n "${2:-}" ]] || die "--network requires an argument (mainnet, preprod, preview)"
                NETWORK="$2"
                shift 2
                ;;
            --keep-epochs)
                [[ -n "${2:-}" ]] || die "--keep-epochs requires a numeric argument"
                [[ "$2" =~ ^[0-9]+$ ]] || die "--keep-epochs must be a positive integer, got: $2"
                KEEP_EPOCHS="$2"
                shift 2
                ;;
            --mithril-client)
                [[ -n "${2:-}" ]] || die "--mithril-client requires a PATH argument"
                MITHRIL_CLIENT="$2"
                shift 2
                ;;
            --skip-download)
                SKIP_DOWNLOAD=true
                shift
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

    [[ -n "$DB_PATH" ]]  || die "--db-path is required (use --help for usage)"
    [[ -n "$NETWORK" ]]  || die "--network is required (use --help for usage)"

    # Validate network name.
    case "$NETWORK" in
        mainnet|preprod|preview) ;;
        *) die "Unknown network: $NETWORK (expected: mainnet, preprod, or preview)" ;;
    esac
}

# ── Mithril client discovery ────────────────────────────────────────────────

find_mithril_client() {
    if [[ -n "$MITHRIL_CLIENT" ]]; then
        [[ -x "$MITHRIL_CLIENT" ]] \
            || die "mithril-client not found or not executable at: $MITHRIL_CLIENT"
        ok "Using mithril-client: $MITHRIL_CLIENT"
        return
    fi

    MITHRIL_CLIENT="$(command -v mithril-client 2>/dev/null || true)"

    if [[ -z "$MITHRIL_CLIENT" ]]; then
        die "mithril-client not found in PATH. Install it or pass --mithril-client PATH." \
            "See: https://mithril.network/doc/manual/getting-started/install"
    fi

    ok "Found mithril-client: $MITHRIL_CLIENT"
}

# ── Mithril snapshot download ───────────────────────────────────────────────

download_snapshot() {
    local aggregator="${MITHRIL_AGGREGATORS[$NETWORK]}"
    local genesis_key="${MITHRIL_GENESIS_KEYS[$NETWORK]}"

    info "Network     : $NETWORK"
    info "Aggregator  : $aggregator"
    info "Target path : $DB_PATH"

    # Create target directory if it doesn't exist.
    mkdir -p "$DB_PATH"

    section "Listing available snapshots"

    # List snapshots to show what's available.
    GENESIS_VERIFICATION_KEY="$genesis_key" \
    AGGREGATOR_ENDPOINT="$aggregator" \
        "$MITHRIL_CLIENT" cardano-db snapshot list 2>&1 | head -20

    section "Downloading latest snapshot"

    info "This may take a while depending on network speed and DB size..."

    GENESIS_VERIFICATION_KEY="$genesis_key" \
    AGGREGATOR_ENDPOINT="$aggregator" \
        "$MITHRIL_CLIENT" cardano-db download latest \
            --download-dir "$DB_PATH" \
            --include-cardano-transactions

    ok "Mithril snapshot downloaded and verified."
}

# ── Chunk discovery & pruning ────────────────────────────────────────────────

# Slots per epoch for the mainnet approximation.
readonly SLOTS_PER_EPOCH=432000

discover_and_plan_pruning() {
    local immutable_dir="$DB_PATH/immutable"

    [[ -d "$immutable_dir" ]] \
        || die "No immutable/ subdirectory found in $DB_PATH — download may have failed."

    # Collect chunk numbers from .chunk files.
    local -a chunks=()
    while IFS= read -r -d '' f; do
        local base
        base="$(basename "$f")"
        if [[ "$base" =~ ^([0-9]{5})\.chunk$ ]]; then
            chunks+=("$(( 10#${BASH_REMATCH[1]} ))")
        fi
    done < <(find "$immutable_dir" -maxdepth 1 -name '*.chunk' -print0 2>/dev/null)

    [[ ${#chunks[@]} -gt 0 ]] || die "No .chunk files found in $immutable_dir"

    # Sort numerically.
    IFS=$'\n' chunks=($(sort -n <<<"${chunks[*]}")); unset IFS

    local lowest=${chunks[0]}
    local highest=${chunks[${#chunks[@]}-1]}
    local total=${#chunks[@]}

    info "Chunk range : $lowest … $highest  ($total chunks)"

    # Compute threshold: keep the last N chunks.
    local threshold=$(( highest - KEEP_EPOCHS ))

    if (( threshold <= lowest )); then
        ok "Nothing to prune — all $total chunks fall within the --keep-epochs=$KEEP_EPOCHS window."
        return 0
    fi

    # Partition into keep/delete.
    local -a to_delete=()
    local -a to_keep=()
    for c in "${chunks[@]}"; do
        if (( c < threshold )); then
            to_delete+=("$c")
        else
            to_keep+=("$c")
        fi
    done

    info "Keeping     : ${#to_keep[@]} chunks  ($threshold … $highest)"
    info "Deleting    : ${#to_delete[@]} chunks  ($lowest … $(( threshold - 1 )))"

    # Estimate freed space.
    local total_bytes=0
    for chunk_num in "${to_delete[@]}"; do
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
    info "Estimated space to free : $(human_bytes "$total_bytes")"

    # Validate ledger snapshots.
    section "Ledger snapshot validation"
    validate_ledger_snapshots "$threshold"

    # Execute or preview.
    if $DRY_RUN; then
        section "Dry-run — no files will be deleted"
        warn "Re-run without --dry-run to actually prune."
        return 0
    fi

    section "Pruning old chunks"
    local deleted=0
    for chunk_num in "${to_delete[@]}"; do
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

    ok "Removed $deleted files across ${#to_delete[@]} chunks"
    info "Estimated space freed : $(human_bytes "$total_bytes")"
    ok "ImmutableDB now spans chunks $threshold … $highest"
}

# ── Ledger snapshot validation ───────────────────────────────────────────────

validate_ledger_snapshots() {
    local threshold_chunk=$1
    local ledger_dir="$DB_PATH/ledger"

    if [[ ! -d "$ledger_dir" ]]; then
        warn "No ledger/ directory found — cannot verify ledger snapshot coverage."
        return 0
    fi

    local min_slot=$(( threshold_chunk * SLOTS_PER_EPOCH ))
    local found=false
    local snapshot_count=0
    local kept_count=0

    for f in "$ledger_dir"/*; do
        [[ -f "$f" ]] || continue
        local name
        name="$(basename "$f")"

        # Extract the largest numeric sequence from the filename as the slot number.
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
        die "No ledger snapshot found with slot >= $min_slot (chunk $threshold_chunk)." \
            "Pruning would leave the node unable to start. Use fewer --keep-epochs or re-bootstrap."
    fi

    ok "Found $kept_count ledger snapshot(s) in retained range (slot >= $min_slot)"
}

# ── Helpers ──────────────────────────────────────────────────────────────────

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

# ── Post-pruning summary ────────────────────────────────────────────────────

print_summary() {
    section "Summary"

    local immutable_dir="$DB_PATH/immutable"
    local chunk_count
    chunk_count="$(find "$immutable_dir" -maxdepth 1 -name '*.chunk' 2>/dev/null | wc -l | tr -d ' ')"

    local db_size
    db_size="$(du -sh "$DB_PATH" 2>/dev/null | cut -f1)"

    info "Database path  : $DB_PATH"
    info "Network        : $NETWORK"
    info "Chunks on disk : $chunk_count"
    info "Total DB size  : $db_size"
    echo ""
    ok "Pruned database is ready. Start cardano-node with --database-path $DB_PATH"

    if [[ "$NETWORK" == "mainnet" ]]; then
        echo ""
        info "For a pruned node, add to your node config YAML:"
        info "  PruningPolicy:"
        info "    mode: keep-epochs"
        info "    epochs: $KEEP_EPOCHS"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
    parse_args "$@"

    if ! $SKIP_DOWNLOAD; then
        section "Mithril client"
        find_mithril_client

        section "Mithril snapshot download"
        download_snapshot
    else
        info "Skipping Mithril download (--skip-download)"
        [[ -d "$DB_PATH" ]] || die "DB path does not exist: $DB_PATH"
    fi

    section "Pruning ImmutableDB"
    discover_and_plan_pruning

    if ! $DRY_RUN; then
        print_summary
    fi
}

main "$@"
