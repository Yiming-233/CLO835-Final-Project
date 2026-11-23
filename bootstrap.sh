#!/bin/bash
# CLO835 Final Project
# Run on the EC2 Host after Docker, kind and kubectl are installed.
# Run from the project repository: bash bootstrap.sh
set -euo pipefail

# Project variables
STUDENT_ID="101753267"
NAMESPACE="mysql-${STUDENT_ID}"
SECRET_NAME="mysql-secrets-${STUDENT_ID}"

# Enter the project directory
cd "$(dirname "$0")"

kind create cluster --config kind-config.yaml --wait 180s

kubectl wait --for=condition=Ready nodes --all --timeout=180s

kubectl get nodes -o wide
kubectl get storageclass standard

########################################################
# Tasks 1 and 7 - Namespace and Secret
########################################################

# Replace only the project-specific placeholders
sed -i \
  -e "s|\${NAMESPACE}|${NAMESPACE}|g" \
  -e "s|\${SECRET_NAME}|${SECRET_NAME}|g" \
  manifests/*.yaml

# Create the Namespace before creating the Secret
kubectl apply -f manifests/00-namespace.yaml

# Generate passwords and create the Secret
kubectl create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=root-password="$(openssl rand -hex 16)" \
  --from-literal=replication-password="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml |
  kubectl apply -f -

kubectl apply -f manifests/

########################################################
# Task 10 - Wait for the MySQL StatefulSet
########################################################
kubectl rollout status statefulset/mysql \
  -n "$NAMESPACE" --timeout=300s

kubectl get pods,pvc -n "$NAMESPACE"

########################################################
# Task 4 - Display Replication Status
########################################################
# Check replication on both replicas
for pod in mysql-1 mysql-2; do
  echo "$pod:"
  kubectl exec "$pod" -n "$NAMESPACE" -c mysql -- \
    sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
done

# Create the database, table and five initial rows
kubectl exec -i mysql-0 -n "$NAMESPACE" -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<SQL
CREATE DATABASE IF NOT EXISTS clo835;
USE clo835;

CREATE TABLE IF NOT EXISTS students (
  seq BIGINT UNSIGNED AUTO_INCREMENT PRIMARY KEY,
  student_id VARCHAR(20) NOT NULL,
  created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

INSERT INTO students (student_id) VALUES
('${STUDENT_ID}'),
('${STUDENT_ID}'),
('${STUDENT_ID}'),
('${STUDENT_ID}'),
('${STUDENT_ID}');
SQL

########################################################
# Task 8 - Verify Seed Data on mysql-2
########################################################
for attempt in {1..60}; do
  seed_count=$(kubectl exec mysql-2 -n "$NAMESPACE" -c mysql -- \
    sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -N -B \
      -e "SELECT COUNT(*) FROM clo835.students WHERE seq BETWEEN 1 AND 5;"' \
    2>/dev/null || true)

  if [[ "$seed_count" == "5" ]]; then
    break
  fi

  sleep 2
done

if [[ "$seed_count" != "5" ]]; then
  echo "Seed data verification failed on mysql-2." >&2
  exit 1
fi

kubectl exec mysql-2 -n "$NAMESPACE" -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table \
    -e "SELECT seq, student_id, created_at FROM clo835.students ORDER BY seq;"'