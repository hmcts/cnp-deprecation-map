#!/bin/bash
deprecation_config_file="../nagger-versions.yaml"
# Use yq to extract the version for Angular Core
angular_version=$(yq eval '.npm["angular/core"].version' "$deprecation_config_file")
echo "Current version is: ${angular_version}"

date_to_timestamp() {
    # If debugging locally use below date instead   
    # date -jf "%Y-%m-%d" "$1" +%s
    date -d "$1" +%s
}
timestamp_to_date() {
    date -d "@$1" "+%Y-%m-%d"
}

angular_eol_data=$(curl -s https://endoflife.date/api/angular.json | jq -c '.[]')

# Get the current date in Unix timestamp
current_date=$(date +%s)
min_diff=""
latest_supported_version=""

for entry in ${angular_eol_data}; do
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

echo "Cycle with closest end of life date to current date: $latest_supported_version"

if [[ $angular_version -lt $latest_supported_version ]];then
    echo "New version ${latest_supported_version} needed in deprecation map"
    git config user.name github-actions
    git config user.email github-actions@github.com
    git pull
    git checkout -b angular-update
    yq eval -i '.npm["angular/core"].version = '\"$latest_supported_version\" $deprecation_config_file
    # Add 30 days
    one_month_from_now=$(expr $current_date + 2592000)
    one_month_from_now=$(timestamp_to_date "$one_month_from_now")
    yq eval -i '.npm["angular/core"].date_deadline = '\"$one_month_from_now\" $deprecation_config_file
    git add "$deprecation_config_file"
    git commit -m "Auto-Updating Angular Version"
    git push --set-upstream origin angular-update

    pr_args=(
        --title "Update Angular Version"
        --body "Automated updates for Angular deprecations"
        --base master
        --head angular-update
    )
    gh pr create "${pr_args[@]}"
else
    echo "File is showing most recent supported Angular version already"
fi
