#!/bin/bash
########################################################
# Task 9 - Write one row per second and log confirmed IDs
# Loop pattern: Week14/localMachine.sh, Step 5
########################################################
# Stop on errors, unset variables and failed pipelines.
set -euo pipefail

STUDENT_ID="101753267"
NAMESPACE="mysql-${STUDENT_ID}"

# Specify the primary Pod: ./writer.sh mysql-0 or ./writer.sh mysql-1
PRIMARY_POD="$1"

echo "Writing to $PRIMARY_POD. Press Ctrl+C to stop."

# Loop pattern adapted from Week14/localMachine.sh
while sleep 1; do
  # Insert and read its ID in the same MySQL connection
  if seq=$(kubectl exec -i "$PRIMARY_POD" -n "$NAMESPACE" -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B' <<SQL
INSERT INTO clo835.students (student_id) VALUES ('$STUDENT_ID');
SELECT LAST_INSERT_ID();
SQL
); then
    echo "$(date -Is) pod=$PRIMARY_POD seq=$seq student=$STUDENT_ID" | tee -a writer-ack.log
  else
    echo "Write result uncertain. Stop and check the database." >&2
    exit 1
  fi
done