#!/bin/bash

# Load environment variables from .env
source .env

# Load the API token from the environment or prompt the user
if [ -z "$API_KEY" ]; then
  echo "Error: API_KEY environment variable not set."
  echo "Export your API key using: export API_KEY=your-token"
  exit 1
fi

# Base API URL and company ID
BASE_URL="https://api.kinsta.com/v2"
COMPANY_ID="<your_company_id>"

# Check if the company ID is set
if [ "$COMPANY_ID" == "<your_company_id>" ]; then
  echo "Error: COMPANY_ID is not set. Please replace <your_company_id> with your actual company ID."
  exit 1
fi

# Function to get the list of sites (raw response)
get_sites_list() {
  API_URL="$BASE_URL/sites?company=$COMPANY_ID"

  echo "Fetching all sites for company ID: $COMPANY_ID..."
  
  RESPONSE=$(curl -s -X GET "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json")

  # Check for errors
  if [ -z "$RESPONSE" ]; then
    echo "Error: No response from the API."
    exit 1
  fi

  echo "$RESPONSE"
}

list_sites() {
  RESPONSE=$(get_sites_list)

  if [ -z "$RESPONSE" ]; then
    echo "Error: No response from the API while fetching sites."
    exit 1
  fi

  echo "Company Sites:"
  echo "--------------"
  # Clean the RESPONSE before passing it to jq
  CLEAN_RESPONSE=$(echo "$RESPONSE" | tr -d '\r' | sed 's/^[^{]*//') # Removes extra characters before the JSON starts

  echo "$CLEAN_RESPONSE" | jq -r '.company.sites[] | "\(.display_name) (\(.name)) - Status: \(.status)"'
}

# Function to fetch site details by site name
get_site_details_by_name() {
  SITE_NAME=$1
  if [ -z "$SITE_NAME" ]; then
    echo "Error: No site name provided. Usage: $0 details-name <site_name>"
    return 1
  fi

  RESPONSE=$(get_sites_list)

  echo "Searching for site with name: $SITE_NAME..."

  # Clean the RESPONSE before parsing
  CLEAN_RESPONSE=$(echo "$RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  # Extract the site ID for the given site name
  SITE_ID=$(echo "$CLEAN_RESPONSE" | jq -r --arg SITE_NAME "$SITE_NAME" '.company.sites[] | select(.name == $SITE_NAME) | .id')

  if [ -z "$SITE_ID" ]; then
    echo "Error: Site with name \"$SITE_NAME\" not found."
    return 1
  fi

  echo "Found site ID: $SITE_ID for site name: $SITE_NAME"

  # Fetch site details using the site ID
  API_URL="$BASE_URL/sites/$SITE_ID"

  SITE_RESPONSE=$(curl -s -X GET "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json")

  echo "$SITE_RESPONSE"
}

# Function to display site details by site name
site_details_by_name() {
  RESPONSE=$(get_site_details_by_name "$1")

  if [ -z "$RESPONSE" ]; then
    echo "Error: No response from the API while fetching site details."
    exit 1
  fi

  echo "Site Details Response:"

  CLEAN_RESPONSE=$(echo "$RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  # Parse and display the site details
  echo "$CLEAN_RESPONSE" | jq -r '[
    "Display Name: \(.site.display_name)",
    "Name: \(.site.name)",
    "Status: \(.site.status)",
    "Primary Domain: https://\(.site.environments[0].primaryDomain.name)",
    "Environments: " + (.site.environments[] | "  - \(.display_name) (\(.name))")
  ] | join("\n")'
}

# Function to get the environment ID by site name and environment name
get_environment_id_by_name() {
  SITE_NAME=$1
  ENV_NAME=$2

  if [ -z "$SITE_NAME" ] || [ -z "$ENV_NAME" ]; then
    echo "Error: Both site name and environment name are required."
    echo "Usage: $0 get-environment-id <site_name> <environment_name>"
    return 1
  fi

  # Fetch the site ID by site name
  SITE_RESPONSE=$(get_site_details_by_name "$SITE_NAME")

  if [ $? -ne 0 ]; then
    echo "Error: Could not fetch site details for site \"$SITE_NAME\"."
    return 1
  fi

  CLEAN_RESPONSE=$(echo "$SITE_RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  SITE_ID=$(echo "$CLEAN_RESPONSE" | jq -r '.site.id')

  if [ -z "$SITE_ID" ]; then
    echo "Error: Site ID not found for site \"$SITE_NAME\"."
    return 1
  fi

  echo "Fetching environments for site ID: $SITE_ID..."

  # Fetch environments for the site
  API_URL="$BASE_URL/sites/$SITE_ID/environments"

  ENV_RESPONSE=$(curl -s -X GET "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json")

  if [ -z "$ENV_RESPONSE" ]; then
    echo "Error: No response from the API while fetching environments."
    return 1
  fi

  CLEAN_RESPONSE=$(echo "$ENV_RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  # Extract the environment ID by environment name
  ENV_ID=$(echo "$CLEAN_RESPONSE" | jq -r --arg ENV_NAME "$ENV_NAME" '.site.environments[] | select(.name == $ENV_NAME) | .id')

  if [ -z "$ENV_ID" ]; then
    echo "Error: Environment \"$ENV_NAME\" not found for site \"$SITE_NAME\"."
    return 1
  fi

  echo "Found environment ID: $ENV_ID for environment name: $ENV_NAME"
  echo "$ENV_ID"
}

# Function to trigger a manual backup
trigger_manual_backup() {
  SITE_NAME=$1
  DEFAULT_TAG="default-backup"

  if [ -z "$SITE_NAME" ]; then
    echo "Error: Site name is required."
    echo "Usage: $0 trigger-backup <site_name>"
    return 1
  fi

  # Fetch the site details and list of environments
  SITE_RESPONSE=$(get_site_details_by_name "$SITE_NAME")

  if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch site details for site \"$SITE_NAME\"."
    return 1
  fi

  CLEAN_RESPONSE=$(echo "$SITE_RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  # Extract and display available environments
  ENVIRONMENTS=$(echo "$CLEAN_RESPONSE" | jq -r '.site.environments[] | "\(.name): \(.id)"')

  echo "Available Environments for \"$SITE_NAME\":"
  echo "$ENVIRONMENTS"

  # Prompt user to select an environment by name
  read -p "Enter the environment name to back up (e.g., staging, live): " ENV_NAME

  if [ -z "$ENV_NAME" ]; then
    echo "Error: No environment name provided."
    return 1
  fi

  # Fetch the environment ID
  ENV_ID=$(echo "$CLEAN_RESPONSE" | jq -r --arg ENV_NAME "$ENV_NAME" '.site.environments[] | select(.name == $ENV_NAME) | .id')
  
  if [ -z "$ENV_ID" ]; then
    echo "Error: Environment \"$ENV_NAME\" not found for site \"$SITE_NAME\"."
    return 1
  fi

  echo "Found environment ID: $ENV_ID for environment name: $ENV_NAME"

  # Fetch manual backups for the environment
  API_URL="$BASE_URL/sites/environments/$ENV_ID/backups"

  BACKUPS_RESPONSE=$(curl -s -X GET "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json")

  if [ -z "$BACKUPS_RESPONSE" ]; then
    echo "Error: Failed to fetch backups for environment \"$ENV_NAME\"."
    return 1
  fi

  CLEAN_RESPONSE=$(echo "$BACKUPS_RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  # Count the number of manual backups
  MANUAL_BACKUPS=$(echo "$CLEAN_RESPONSE" | jq '[.environment.backups[] | select(.type == "manual")]')
  BACKUP_COUNT=$(echo "$MANUAL_BACKUPS" | jq 'length')

  if [ "$BACKUP_COUNT" -ge 5 ]; then
    echo "Manual backup limit reached (5 backups)."
    
    # Find the oldest backup
    OLDEST_BACKUP=$(echo "$MANUAL_BACKUPS" | jq -r 'sort_by(.created_at) | .[0]')
    OLDEST_BACKUP_NAME=$(echo "$OLDEST_BACKUP" | jq -r '.note')
    OLDEST_BACKUP_ID=$(echo "$OLDEST_BACKUP" | jq -r '.id')

    echo "The oldest manual backup is \"$OLDEST_BACKUP_NAME\"."
    read -p "Do you want to delete this backup to create a new one? (yes/no): " CONFIRM

    if [ "$CONFIRM" != "yes" ]; then
      echo "Aborting backup creation."
      return 1
    fi

    # Delete the oldest backup
    DELETE_URL="$BASE_URL/sites/environments/backups/$OLDEST_BACKUP_ID"
    DELETE_RESPONSE=$(curl -s -X DELETE "$DELETE_URL" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json")

    echo "Delete Response:"
    echo "$DELETE_RESPONSE" | jq -r '[
      "Operation ID: \(.operation_id)",
      "Message: \(.message)",
      "Status: \(.status)"
    ] | join("\n")'
  fi

  # Prompt user for backup tag
  read -p "Enter a backup tag (or press Enter to use \"$DEFAULT_TAG\"): " BACKUP_TAG
  
  if [ -z "$BACKUP_TAG" ]; then
    BACKUP_TAG="$DEFAULT_TAG"
  fi

  echo "Using backup tag: $BACKUP_TAG"

  # Trigger the manual backup
  echo "Triggering manual backup for environment ID: $ENV_ID with tag: $BACKUP_TAG..."

  API_URL="$BASE_URL/sites/environments/$ENV_ID/manual-backups"

  RESPONSE=$(curl -s -X POST "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"tag\": \"$BACKUP_TAG\"}")

  if [ -z "$RESPONSE" ]; then
    echo "Error: No response from the API while triggering the manual backup."
    return 1
  fi

  # Parse and display the response
  echo "Backup Trigger Response:"
  echo "$RESPONSE" | jq -r '[
    "Operation ID: \(.operation_id)",
    "Message: \(.message)",
    "Status: \(.status)"
  ] | join("\n")'
}

# Function to list outdated plugins for a site environment
list_outdated_plugins() {
  SITE_NAME=$1

  if [ -z "$SITE_NAME" ]; then
    echo "Error: Site name is required."
    echo "Usage: $0 list-plugins <site_name>"
    return 1
  fi

  # Fetch the site details and list of environments
  SITE_RESPONSE=$(get_site_details_by_name "$SITE_NAME")
  if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch site details for site \"$SITE_NAME\"."
    return 1
  fi

  # Clean the response
  CLEAN_SITE_RESPONSE=$(echo "$SITE_RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  # Extract and display available environments
  ENVIRONMENTS=$(echo "$CLEAN_SITE_RESPONSE" | jq -r '.site.environments[] | "\(.name): \(.display_name)"')
  echo "Available Environments for \"$SITE_NAME\":"
  echo "$ENVIRONMENTS"

  # Prompt user to select an environment by name
  read -p "Enter the environment name to list plugins (e.g., staging, live): " ENV_NAME
  if [ -z "$ENV_NAME" ]; then
    echo "Error: No environment name provided."
    return 1
  fi

  # Fetch the environment ID
  ENV_ID=$(echo "$CLEAN_SITE_RESPONSE" | jq -r --arg ENV_NAME "$ENV_NAME" '.site.environments[] | select(.name == $ENV_NAME) | .id')
  if [ -z "$ENV_ID" ]; then
    echo "Error: Environment \"$ENV_NAME\" not found for site \"$SITE_NAME\"."
    return 1
  fi

  echo "Found environment ID: $ENV_ID for environment name: $ENV_NAME"

  # Fetch plugins for the selected environment
  API_URL="$BASE_URL/sites/environments/$ENV_ID/plugins"
  PLUGINS_RESPONSE=$(curl -s -X GET "$API_URL" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json")

  # Clean the response
  CLEAN_PLUGINS_RESPONSE=$(echo "$PLUGINS_RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  if [ -z "$CLEAN_PLUGINS_RESPONSE" ]; then
    echo "Error: Failed to fetch plugins for environment \"$ENV_NAME\"."
    return 1
  fi

  # Filter plugins with "update": "available"
  OUTDATED_PLUGINS=$(echo "$CLEAN_PLUGINS_RESPONSE" | jq -r '.environment.container_info.wp_plugins.data[] | select(.update == "available")')

  if [ -z "$OUTDATED_PLUGINS" ]; then
    echo "No outdated plugins found for \"$ENV_NAME\"."
    return 0
  fi

  # Display outdated plugins
  echo "Outdated Plugins for \"$ENV_NAME\":"
  echo "$OUTDATED_PLUGINS" | jq -r '[
    "Plugin: \(.title) (\(.name))",
    "  Current Version: \(.version)",
    "  Update Version: \(.update_version)"
  ] | join("\n")'
}

# Function to update a plugin across all sites
update_plugin_across_sites() {
  PLUGIN_NAME=$1

  if [ -z "$PLUGIN_NAME" ]; then
    echo "Error: Plugin name is required."
    echo "Usage: $0 update-plugin <plugin_name>"
    return 1
  fi

  echo "Fetching all sites in the company..."

  # Fetch all sites in the company
  SITES_RESPONSE=$(get_sites_list)
  if [ $? -ne 0 ]; then
    echo "Error: Failed to fetch sites."
    return 1
  fi

  # Clean the response
  CLEAN_SITES_RESPONSE=$(echo "$SITES_RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

  # Iterate through all sites and their environments
  SITES_WITH_OUTDATED_PLUGIN=()
  while IFS= read -r SITE; do
    SITE_ID=$(echo "$SITE" | jq -r '.id')
    SITE_NAME=$(echo "$SITE" | jq -r '.name')
    SITE_DISPLAY_NAME=$(echo "$SITE" | jq -r '.display_name')

    echo "Checking environments for site \"$SITE_DISPLAY_NAME\"..."

    SITE_DETAILS=$(get_site_details_by_name "$SITE_NAME")
    CLEAN_SITE_DETAILS=$(echo "$SITE_DETAILS" | tr -d '\r' | sed 's/^[^{]*//')

    ENVIRONMENTS=$(echo "$CLEAN_SITE_DETAILS" | jq -r '.site.environments[] | "\(.id):\(.name):\(.display_name)"')

    while IFS= read -r ENV; do
      ENV_ID=$(echo "$ENV" | cut -d: -f1)
      ENV_NAME=$(echo "$ENV" | cut -d: -f2)
      ENV_DISPLAY_NAME=$(echo "$ENV" | cut -d: -f3)

      # Fetch plugins for the environment
      API_URL="$BASE_URL/sites/environments/$ENV_ID/plugins"
      PLUGINS_RESPONSE=$(curl -s -X GET "$API_URL" \
        -H "Authorization: Bearer $API_KEY" \
        -H "Content-Type: application/json")

      CLEAN_PLUGINS_RESPONSE=$(echo "$PLUGINS_RESPONSE" | tr -d '\r' | sed 's/^[^{]*//')

      OUTDATED_PLUGIN=$(echo "$CLEAN_PLUGINS_RESPONSE" | jq -r --arg PLUGIN_NAME "$PLUGIN_NAME" '.environment.container_info.wp_plugins.data[] | select(.name == $PLUGIN_NAME and .update == "available")')

      if [ ! -z "$OUTDATED_PLUGIN" ]; then
        OUTDATED_VERSION=$(echo "$OUTDATED_PLUGIN" | jq -r '.version')
        UPDATE_VERSION=$(echo "$OUTDATED_PLUGIN" | jq -r '.update_version')

        echo "Outdated plugin \"$PLUGIN_NAME\" found in \"$SITE_DISPLAY_NAME\" (Environment: $ENV_DISPLAY_NAME)"
        echo "  Current Version: $OUTDATED_VERSION"
        echo "  Update Version: $UPDATE_VERSION"

        # Add to list of sites with outdated plugin
        SITES_WITH_OUTDATED_PLUGIN+=("$SITE_DISPLAY_NAME:$ENV_DISPLAY_NAME:$ENV_ID:$UPDATE_VERSION")
      fi
    done <<< "$ENVIRONMENTS"
  done <<< "$(echo "$CLEAN_SITES_RESPONSE" | jq -c '.company.sites[]')"

  # Display sites with outdated plugin
  if [ ${#SITES_WITH_OUTDATED_PLUGIN[@]} -eq 0 ]; then
    echo "No outdated plugin \"$PLUGIN_NAME\" found across sites."
    return 0
  fi

  echo "The following sites have outdated plugin \"$PLUGIN_NAME\":"
  for SITE_INFO in "${SITES_WITH_OUTDATED_PLUGIN[@]}"; do
    IFS=: read -r SITE_DISPLAY_NAME ENV_DISPLAY_NAME ENV_ID UPDATE_VERSION <<< "$SITE_INFO"
    echo "- $SITE_DISPLAY_NAME (Environment: $ENV_DISPLAY_NAME, Update Version: $UPDATE_VERSION)"
  done

  # Prompt user to update all or select specific sites
  read -p "Do you want to update all sites? (yes/no): " UPDATE_ALL
  if [ "$UPDATE_ALL" == "no" ]; then
    echo "You can select specific sites to update. Enter their numbers separated by spaces:"
    for i in "${!SITES_WITH_OUTDATED_PLUGIN[@]}"; do
      IFS=: read -r SITE_DISPLAY_NAME ENV_DISPLAY_NAME ENV_ID UPDATE_VERSION <<< "${SITES_WITH_OUTDATED_PLUGIN[$i]}"
      echo "$((i+1))) $SITE_DISPLAY_NAME (Environment: $ENV_DISPLAY_NAME)"
    done
    read -p "Enter your choices: " CHOICES

    SELECTED_SITES=()
    for CHOICE in $CHOICES; do
      INDEX=$((CHOICE-1))
      SELECTED_SITES+=("${SITES_WITH_OUTDATED_PLUGIN[$INDEX]}")
    done
  else
    SELECTED_SITES=("${SITES_WITH_OUTDATED_PLUGIN[@]}")
  fi

  # Update the plugin for selected sites
  echo "Updating plugin \"$PLUGIN_NAME\"..."
  for SITE_INFO in "${SELECTED_SITES[@]}"; do
    IFS=: read -r SITE_DISPLAY_NAME ENV_DISPLAY_NAME ENV_ID UPDATE_VERSION <<< "$SITE_INFO"
    API_URL="$BASE_URL/sites/environments/$ENV_ID/plugins"
    UPDATE_RESPONSE=$(curl -s -X PUT "$API_URL" \
      -H "Authorization: Bearer $API_KEY" \
      -H "Content-Type: application/json" \
      -d "{\"name\": \"$PLUGIN_NAME\", \"update_version\": \"$UPDATE_VERSION\"}")

    echo "Update Response for $SITE_DISPLAY_NAME (Environment: $ENV_DISPLAY_NAME):"
    echo "$UPDATE_RESPONSE" | jq -r '[
      "Operation ID: \(.operation_id)",
      "Message: \(.message)",
      "Status: \(.status)"
    ] | join("\n")'
  done
}

# Main logic to call functions based on input
if [ "$1" == "list" ]; then
  list_sites
elif [ "$1" == "site-details" ]; then
  site_details_by_name "$2"
elif [ "$1" == "get-environment-id" ]; then
  SITE_NAME="$2"
  ENV_NAME="$3"
  if [ -z "$SITE_NAME" ] || [ -z "$ENV_NAME" ]; then
    echo "Usage: $0 get-environment-id <site_name> <environment_name>"
    exit 1
  fi
  get_environment_id_by_name "$SITE_NAME" "$ENV_NAME"
elif [ "$1" == "backup" ]; then
  SITE_NAME="$2"
  if [ -z "$SITE_NAME" ]; then
    echo "Usage: $0 backup <site_name>"
    exit 1
  fi
  trigger_manual_backup "$SITE_NAME"
elif [ "$1" == "list-outdated-plugins" ]; then
  SITE_NAME="$2"
  if [ -z "$SITE_NAME" ]; then
    echo "Usage: $0 list-outdated-plugins <site_name>"
    exit 1
  fi
  list_outdated_plugins "$SITE_NAME"
elif [ "$1" == "update-plugin" ]; then
  PLUGIN_NAME="$2"
  if [ -z "$PLUGIN_NAME" ]; then
    echo "Usage: $0 update-plugin <plugin_name>"
    exit 1
  fi
  update_plugin_across_sites "$PLUGIN_NAME"
else
  echo "Usage: $0 [list | site-details | get-environment-id | backup | list-outdated-plugins | update-plugin]"
  exit 1
fi
