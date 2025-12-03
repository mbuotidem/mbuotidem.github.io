#manage_all_user_sessions.sh
#!/bin/bash
set -euo pipefail

: "${DB_HOST?}"
: "${DB_ADMIN_USER?}"
: "${DB_NAME?}"
: "${OKTA_USERS_JSON?}"
: "${PGPASSWORD?}"

OUTPUT_FILE="terminated_sessions.json"
# Initialize/create the output file with an empty JSON array.
# This ensures the file exists even if the script exits prematurely later.
echo "[]" > "$OUTPUT_FILE"

# Convert Okta users JSON to SQL array
OKTA_USERS_SQL_ARRAY=$(
  echo "$OKTA_USERS_JSON" | jq -r --arg q "'" '
    if length > 0 then "ARRAY[" + $q + join($q + "," + $q) + $q + "]"
    else "ARRAY[]::text[]"
    end
  '
)

# SQL query to find and terminate sessions for non-superusers not in the Okta list,
# and return a JSON array of the terminated usernames.
SQL_QUERY="
SELECT COALESCE(json_agg(usename), '[]'::json)
FROM (
    SELECT usename, pg_terminate_backend(pid)
    FROM pg_stat_activity psa
    JOIN pg_roles pr ON psa.usesysid = pr.oid
    WHERE
      psa.pid <> pg_backend_pid()
      AND psa.usename ~ '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}$'
      AND psa.usename <> ALL (${OKTA_USERS_SQL_ARRAY})
      AND pr.rolname <> 'rdsadmin'
      AND pr.rolcanlogin
      AND NOT pr.rolsuper
) t;
"

# Execute the query and capture the resulting JSON array.
TERMINATED_USERS_JSON=$(
  psql -v ON_ERROR_STOP=1 \
    -h "$DB_HOST" \
    -U "$DB_ADMIN_USER" \
    -d "$DB_NAME" \
    -tAc "${SQL_QUERY}"
)

# Write the JSON array of terminated users to the output file.
# If the query returned nothing, write an empty array.
echo "${TERMINATED_USERS_JSON:-[]}" > "$OUTPUT_FILE"

