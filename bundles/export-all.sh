#!/bin/bash

# Export all bundle repositories to JSON files
# Uses bundle._get_repository_export() SQL function

database_name=$1
if [ -z "$database_name" ]; then
  echo "usage: $0 <database_name>"
  exit 1
fi

# Export all repositories using SQL function
PGPASSWORD=aquameta psql -h localhost -U aquameta -d $database_name -At -c "SET ROLE ai_agent_mistral_vibe; SELECT name FROM bundle.repository ORDER BY name;" | while read repo; do
    echo "Exporting $repo..."
    PGPASSWORD=aquameta psql -h localhost -U aquameta -d $database_name -At -c "SET ROLE ai_agent_mistral_vibe; SELECT bundle._get_repository_export(id) FROM bundle.repository WHERE name = '$repo';" > "$repo.json"
    # Remove any leading non-JSON lines (like "SET" from psql output)
    sed -i '1{/^SET$/d}' "$repo.json"
    echo "Exported $repo to $repo.json"
done

echo "All bundles exported."
