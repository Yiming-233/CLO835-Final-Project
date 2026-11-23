#!/bin/bash
########################################################
# Task 9 - Write one row per second and log confirmed IDs
########################################################
set -euo pipefail

STUDENT_ID="101753267"
NAMESPACE="mysql-${STUDENT_ID}"
PRIMARY_POD="${1:-mysql-0}"

cd "$(dirname "$0")"

echo "Writing to $PRIMARY_POD. Press Ctrl+C to stop."

# Loop structure adapted from Week14/localMachine.sh, Step 5
while sleep 1; do
  if seq=$(kubectl exec "$PRIMARY_POD" -n "$NAMESPACE" -c mysql -- \
    sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "$1"' sh \
    "INSERT INTO clo835.students (student_id) VALUES ('$STUDENT_ID');
     SELECT LAST_INSERT_ID();"); then

    echo "$(date -Is) pod=$PRIMARY_POD seq=$seq student=$STUDENT_ID" |
      tee -a writer-ack.log
  else
    echo "Write result uncertain. Stop and check the database." >&2
    exit 1
  fi

done