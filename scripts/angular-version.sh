#!/bin/bash
anne_token=""
deprecation_config_file="../nagger-versions.yaml"
# Use yq to extract the version for Angular Core
# angular_version=$(yq eval '.npm["angular/core"].version' "$deprecation_config_file")
# echo "Current version is: ${angular_version}"


extract_data() {
    local key="$1" 
    local subkey="$2" 

    version=$(yq eval ".${key}[\"${subkey}\"] | .version" "$deprecation_config_file")
    deadline=$(yq eval ".${key}[\"${subkey}\"] | .date_deadline" "$deprecation_config_file")
    endpoint=$(yq eval ".${key}[\"${subkey}\"] | .release_api" "$deprecation_config_file")

    echo "$version,$deadline,$endpoint"
}

# This will get the latest standard release and ignore release candidates, prereleases & alpha/beta, etc
get_latest_version() {
    local endpoint="$1"

    versions=$(curl -s "$endpoint" | jq -r '.[] | select(.prerelease == false) | .tag_name' | sed 's/^[vV]//' | sort -V -r)

    for version in $versions; do

        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]$ ]]; then
            latest_version=$version
            break
        fi

    done

    echo "$latest_version"
}

compare_versions() {
    local current_version="$1"
    local latest_version="$2"

    # Extract major versions for comparison
    current_major="${current_version%%.*}"
    required_major="${latest_version%%.*}"

    # Check for major version changes
    if [[ "$current_major" -ne "$required_major" ]]; then
        echo "Major version change detected: Current=$current_major, Required=$required_major"
        echo "This may indicate breaking changes."
    fi

    # Compare full versions using sort -V
    if [ "$(printf '%s\n' "$current_version" "$latest_version" | sort -V | head -n 1)" = "$latest_version" ]; then
        echo "Version is sufficient: $current_version"
    else
        echo "Version is outdated: $current_version (minimum required: $latest_version)"
    fi
}


keys=("terraform" "helm" "npm")
declare -a subkeys  # Regular indexed array

for key in "${keys[@]}"; do
    if [[ "${key}" == "npm" ]]; then
        echo "npm"
    else
        
         # Clear the subkeys array for the new key
        subkeys=()

        # Read the output of yq eval line by line and append to the array
        while IFS= read -r subkey; do
            subkeys+=("$subkey")
        done < <(yq eval ".${key} | keys | .[]" "$deprecation_config_file")

        # Loop through the subkeys array
        for subkey in "${subkeys[@]}"; do
            # Call the function and store the returned values
            data=$(extract_data "${key}" "${subkey}")

            # Split the result into separate variables
            IFS=',' read -r version deadline endpoint <<< "$data"

            # Access the individual values
            echo "Subkey: $subkey"
            echo "Version: $version"
            echo "Deadline: $deadline"
            echo "Endpoint: $endpoint"

            endpoint_token=$(echo "$endpoint" | sed "s|https://|https://$anne_token@|")
            #echo "$endpoint_token"

            latest_version=$(get_latest_version "$endpoint_token")

            compare_versions "$version" "$latest_version"

        done
    fi
done


# for each key in keys_for_endpoint_checking:
#     if key != "angular":
#     version, deadline, endpoint = get_stuff(subkey)
#     deadline = subkey.date_deadline
#     endpoint =  subkey.release_endpoint

#     make call to endpoint

#     compare

#     update file if needed - do we want to update directly or store and increment a chang counter so we're only checking out after we've evaluated and need to make changes
#         - then we can run through the dict or whatever and make the actual file changes post new branch checkout 
#     else:
#      run our angluar stuff - npm key could expand for more than just singualr anuglar but the code in this script is angular specific so we should check the subkey as well
# reiteration


# date_to_timestamp() {
#     # If debugging locally use below date instead   
#     # date -jf "%Y-%m-%d" "$1" +%s
#     date -d "$1" +%s
# }
# timestamp_to_date() {
#     date -d "@$1" "+%Y-%m-%d"
# }

# angular_eol_data=$(curl -s https://endoflife.date/api/angular.json | jq -c '.[]')

# # Get the current date in Unix timestamp
# current_date=$(date +%s)
# min_diff=""
# latest_supported_version=""

# for entry in ${angular_eol_data}; do
#     eol=$(echo "${entry}" | jq -r '.eol')
#     eol_date=$(date_to_timestamp "$eol")

#     # Calculate the difference between current date and end of life date
#     diff=$((eol_date - current_date))
#     abs_diff=${diff#-}

#     # Check if the difference is smaller than the minimum or if it's the first iteration
#     if [ -z "$min_diff" ] || [ "$abs_diff" -lt "$min_diff" ]; then
#         min_diff="$abs_diff"
#         latest_supported_version=$(echo "${entry}" | jq -r '.cycle')
#     fi
# done

# echo "Cycle with closest end of life date to current date: $latest_supported_version"

# if [[ $angular_version -lt $latest_supported_version ]];then
#     echo "New version ${latest_supported_version} needed in deprecation map"
#     git config user.name github-actions
#     git config user.email github-actions@github.com
#     git pull
#     git checkout -b angular-update
#     yq eval -i '.npm["angular/core"].version = '\"$latest_supported_version\" $deprecation_config_file
#     # Add 30 days
#     one_month_from_now=$(expr $current_date + 2592000)
#     one_month_from_now=$(timestamp_to_date "$one_month_from_now")
#     yq eval -i '.npm["angular/core"].date_deadline = '\"$one_month_from_now\" $deprecation_config_file
#     git add "$deprecation_config_file"
#     git commit -m "Auto-Updating Angular Version"
#     git push --set-upstream origin angular-update

#     pr_args=(
#         --title "Update Angular Version"
#         --body "Automated updates for Angular deprecations"
#         --base master
#         --head angular-update
#     )
#     gh pr create "${pr_args[@]}"
# else
#     echo "File is showing most recent supported Angular version already"
# fi
