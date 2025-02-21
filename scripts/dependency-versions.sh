#!/bin/bash
deprecation_config_file="../nagger-versions.yaml"
# declare global arrays and variables
declare -A minor_upgrades major_upgrades
declare -a subkeys
current_date=$(date +%s)

extract_data() {

    local key="$1" 
    local subkey="$2" 

    version=$(yq eval ".${key}[\"${subkey}\"] | .version" "$deprecation_config_file")
    deadline=$(yq eval ".${key}[\"${subkey}\"] | .date_deadline" "$deprecation_config_file")

    # Check if release_api key exists - get its value - if not, set to undefined
    if yq eval ".${key}[\"${subkey}\"] | .release_api" "$deprecation_config_file" >/dev/null 2>&1; then
        endpoint=$(yq eval ".${key}[\"${subkey}\"] | .release_api" "$deprecation_config_file")
    else
        endpoint="undefined"
    fi
    echo "$version,$deadline,$endpoint"
}

get_latest_version_github() {
    local endpoint="$1"

    # Get the latest standard release and ignore release candidates, prereleases & alpha/beta, etc
    versions=$(curl -s "$endpoint" | jq -r '.[] | select(.prerelease == false) | .tag_name' | sed 's/^[vV]//' | sort -V -r)
    for version in $versions; do
        if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]$ ]]; then
            latest_version=$version
            break
        fi
    done

    echo "$latest_version"
}

get_latest_version_eol() {
    local endpoint="$1"
    local version="$2"
    local key="$3"
    local subkey="$4"

    eol_data=$(curl -s "$endpoint" | jq -c '.[]')

    # Get the current date in Unix timestamp
    min_diff=""
    latest_supported_version=""

    for entry in ${eol_data}; do
        eol=$(echo "${entry}" | jq -r '.eol')
        eol_date=$(date_to_timestamp "$eol")

        # Calculate the difference between current date and end of life date
        diff=$((eol_date - current_date))
        abs_diff=${diff#-}

        # Check if the difference is smaller than the minimum or if it's the first iteration
        if [ -z "$min_diff" ] || [ "$abs_diff" -lt "$min_diff" ]; then
            min_diff="$abs_diff"
            latest_supported_version=$(echo "${entry}" | jq -r '.cycle')
        fi
    done

    echo "$latest_supported_version"
}

compare_versions() {
    local current_version="$1"
    local latest_version="$2"
    local key="$3"
    local subkey="$4"

    # Extract major version from nagger & latest version for comparison
    current_major="${current_version%%.*}"
    required_major="${latest_version%%.*}"

    # Detect major version change - break if detected
    if [[ "$current_major" -ne "$required_major" ]]; then
        echo "Major version change detected: Current=$current_version, Required=$latest_version Subkey=$subkey"
        
        # Update the major_upgrades associative array with key and encoded subkey
        composite_key="${key}_${subkey}"
        major_upgrades["$composite_key"]="$latest_version"
        return
    fi

    # Check if the current version needs a minor version upgrade
    if [ "$(printf '%s\n' "$current_version" "$latest_version" | sort -V | head -n 1)" = "$latest_version" ]; then
        echo "Version is sufficient: $current_version"
    else
        echo "Version is outdated: $current_version (minimum required: $latest_version)  Subkey=$subkey"
        composite_key="${key}_${subkey}"
        # Update the minor_upgrades associative array with key and encoded subkey
        minor_upgrades["$composite_key"]="$latest_version"
    fi
}


date_to_timestamp() {
    # If debugging locally use below date instead   
    # date -jf "%Y-%m-%d" "$1" +%s
    date -d "$1" +%s
}

timestamp_to_date() {
    date -d "@$1" "+%Y-%m-%d"
}


update_nagger() {
    local key="$1"
    local subkey="$2"
    local latest_version="$3"

    # Update the YAML file using yq
    yq eval -i ".${key}[\"${subkey}\"].version = \"$latest_version\"" "$deprecation_config_file"
    
    # Calculate the new deadline date
    two_months_from_now=$(expr "$current_date" + 5184000)
    two_months_from_now=$(timestamp_to_date "$two_months_from_now")

    # Update nagger version yaml with the new deadline date
    yq eval -i ".${key}[\"${subkey}\"].date_deadline = \"$two_months_from_now\"" "$deprecation_config_file"
}

create_branch() {
    local pr_type="$1"

    if [ "$pr_type" == "minor" ]; then
        branch="minor-updates"
        upgrades=""

        git checkout master
        git pull
        git checkout -b $branch
        
        # loop minor_upgrades entries & split key on _ deliminater to get key & subkey
        for entry in "${!minor_upgrades[@]}"; do
            IFS="_" read -r key subkey <<< "$entry"
            # get value of the new version
            version=${minor_upgrades[$entry]}

            # update nagger versions yaml with new version
            update_nagger "$key" "$subkey" "$version"

            # create comma-separated string of components with minor upgrades 
            if [[ -z "$upgrades" ]]; then
                    upgrades="$subkey"
                else
                    upgrades="$upgrades, $subkey"
            fi
        done

        # commit & create minor upgrades PR
        commit_message="Auto-Updating minor versions - $upgrades"
        create_pr $branch "$commit_message"
    fi

    # loop major_upgrades entries & split key on _ deliminater to get key & subkey
    if [ "$pr_type" = "major" ]; then
        for entry in "${!major_upgrades[@]}"; do
            git checkout master
            IFS="_" read -r key subkey <<< "$entry"
            # get value of the new version
            version=${major_upgrades[$entry]}

            # shorten terraform provider keys as they're quite long
            if [ "$key" == "terraform" ] && [ ! "$subkey" == "terraform" ]; then
                component_name="${subkey#*/}"  
            else
                component_name="$subkey"
            fi

            branch="$key-$component_name-major-update"
            git pull
            git checkout -b "$branch"

            # update nagger versions yaml with new version
            update_nagger "$key" "$subkey" "$version"

            # commit & create PR - one for each major upgrade
            commit_message="Auto-Updating major version - $key $component_name"
            create_pr "$branch" "$commit_message"
        done
    fi  
}

create_pr() {
    local branch="$1"
    local commit_message="$2"

    # create the PR & push to origin remote
    git add "$deprecation_config_file"
    git commit -m "$commit_message"
    git push --set-upstream origin "$branch"
    pr_args=(
        --title "$commit_message"
        --body "$commit_message"
        --base master
        --head "$branch"
    )
    gh pr create "${pr_args[@]}"
}


### MAIN ###
# declare top-level keys to iterate
keys=("terraform" "helm" "npm")

for key in "${keys[@]}"; do     
    # Clear the subkeys array for each new key
    subkeys=()

    # Read the output of yq line by line and append to the subkeys array
    while IFS= read -r subkey; do
        subkeys+=("$subkey")
    done < <(yq eval ".${key} | keys | .[]" "$deprecation_config_file")

    # Loop subkeys & extract version, deadline, and release_api from nagger yaml
    for subkey in "${subkeys[@]}"; do
        data=$(extract_data "${key}" "${subkey}")
        IFS=',' read -r version deadline endpoint <<< "$data"

        # check endpoint
        case "$endpoint" in
            undefined)
                # If release_api is undefined break the loop
                break
                ;;
            *github.com*)
                # Get latest stable version from github API then compare with nagger version
                latest_version=$(get_latest_version_github "$endpoint")
                compare_versions "$version" "$latest_version" "$key" "$subkey"
                ;;
            *endoflife.date*)
                # Get latest supported version from endoflife.date API then compare with nagger version
                latest_version=$(get_latest_version_eol "$endpoint" "$version" "$key" "$subkey")
                compare_versions "$version" "$latest_version" "$key" "$subkey"
                ;;
            *)
                # We should never hit this case due to the use of "undefined" above
                # Here as a catch-all anyway, just in case...
                echo "Could not determine release_api (main):" >&2
                echo "key: $key, subkey: $subkey, release_api: $endpoint" >&2
                exit 1
                ;;
        esac
    done
done

# Global upgrade arrays should now be populated here
# Check if there are any upgrades to be made
if [ ${#major_upgrades[@]} -gt 0 ] || [ ${#minor_upgrades[@]} -gt 0 ]; then
    git config user.name github-actions
    git config user.email github-actions@github.com
    git pull

    if [ ${#minor_upgrades[@]} -gt 0 ]; then
        create_branch "minor"
    fi

    if [ ${#major_upgrades[@]} -gt 0 ]; then
        create_branch "major"
    fi
fi