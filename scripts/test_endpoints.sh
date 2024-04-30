#!/bin/bash
set -euo pipefail

# define paths for scripts and tools
script_dir="$(dirname "$(realpath "$0")")"
root_dir="$(dirname "$script_dir")"
gavel="$script_dir/gavel/target/release/gavel"
jq="/usr/bin/jq"
members_json="$root_dir/members.json"

echo "Using gavel built @ $gavel"

# define the output directory and file
output_dir="/tmp/endpoint_tests"
output_file="$output_dir/results.json"

# initialize the output directory
initialize_output() {
    mkdir -p "$output_dir"
    echo '{}' > "$output_file"
}

# fetch block data from network endpoint
fetch_block_data() {
    local operator="$1"
    local network="$2"
    local endpoint="$3"
    local block_height=100
    local result_file=$(mktemp)

    echo "Fetching data from $operator at $endpoint for $network"
    
    block_data=$("$gavel" fetch "$endpoint" -b "$block_height" 2>&1)
    if [[ $? -ne 0 || -z "$block_data" || "$block_data" == "null" || "$block_data" == "{}" ]]; then
        echo "Failed to fetch block data or received null/empty response"
        return
    fi

    mmr_data=$("$gavel" mmr "$endpoint" "$block_height" 2>&1)
    if [[ $? -ne 0 || -z "$mmr_data" || "$mmr_data" == "null" || "$mmr_data" == "{}" ]]; then
        echo "Failed to fetch MMR data or received null/empty response"
        return
    fi

    # Validate JSON before attempting to parse with jq
    if ! jq -e . <<< "$block_data" >/dev/null; then
        echo "Invalid JSON received for block data"
        return
    fi

    if ! jq -e . <<< "$mmr_data" >/dev/null; then
        echo "Invalid JSON received for MMR data"
        return
    fi

    # Extract the first 16 bits of the first extrinsic if available
    first_extrinsic_bits=$(echo "$block_data" | jq -r '.block.extrinsics[0] // empty | .[0:4]')

    jq -n --argjson block_data "$block_data" --argjson mmr_data "$mmr_data" \
        --arg operator "$operator" --arg network "$network" --arg endpoint "$endpoint" \
        --arg first_extrinsic_bits "$first_extrinsic_bits" '{
            id: $operator,
            network: $network,
            endpoint: $endpoint,
            block_number: ($block_data.block.header.number // null),
            extrinsics_root: ($block_data.block.header.extrinsicsRoot // null),
            parent_hash: ($block_data.block.header.parentHash // null),
            state_root: ($block_data.block.header.stateRoot // null),
            valid: ((($block_data.block.extrinsics // []) | length) > 0 and ($block_data.block.extrinsics[0] // null) != null),
            first_extrinsic_bits: $first_extrinsic_bits,
            oci_enabled: ($mmr_data.proof != null)
        }' > "$result_file"

    update_results "$operator" "$result_file"
    rm "$result_file"
}

# process all endpoints for each operator from a given JSON
process_endpoints() {
    jq -rc '.members | to_entries[]' "$members_json" | while IFS= read -r member; do
        local operator=$(echo "$member" | jq -r '.key')
        local endpoints=$(echo "$member" | jq -r '.value.endpoints | to_entries[]')
        echo "$endpoints" | jq -c '.' | while IFS= read -r endpoint; do
            local network=$(echo "$endpoint" | jq -r '.key')
            local url=$(echo "$endpoint" | jq -r '.value')
            echo "Fetching data for $operator on $network at $url"
            fetch_block_data "$operator" "$network" "$url"
        done
    done
}

# update the results file with new data
update_results() {
    local operator="$1"
    local data_file="$2"
    jq --arg operator "$operator" --slurpfile data "$data_file" '
        .[$operator] = (.[$operator] // []) + $data
    ' "$output_file" > "${output_file}.tmp" && mv "${output_file}.tmp" "$output_file"
}

# main function to run the script
main() {
    initialize_output
    process_endpoints
    echo "All data has been fetched and saved."
}

main
