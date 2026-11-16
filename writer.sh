#!/bin/bash
########################################################
# Task 9 - Continuously insert rows with automatic IDs
########################################################
set -euo pipefail

STUDENT_ID="101753267"
NAMESPACE="mysql-${STUDENT_ID}"
PRIMARY_POD="${1:-mysql-0}"

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "Writing to $PRIMARY_POD. Press Ctrl+C to stop."

while true; do
  # Insert a row and retrieve its ID in the same connection
  if seq=$(kubectl exec "$PRIMARY_POD" -n "$NAMESPACE" -c mysql -- \
    sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B -e "$1"' sh \
    "INSERT INTO clo835.students (student_id)
     VALUES ('$STUDENT_ID');
     SELECT LAST_INSERT_ID();"); then

    # Record the sequence only after success is acknowledged
    printf '%s\t%s\t%s\t%s\n' \
      "$(date -Is)" "$PRIMARY_POD" "$seq" "$STUDENT_ID" |
      tee -a writer-ack.log
  else
    echo "Write result uncertain. Check the database before restarting." >&2
    exit 1
  fi

  sleep 1
done