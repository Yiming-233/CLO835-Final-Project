#!/bin/bash
# CLO835 Final Project
# Run on the EC2 Host after Docker, kind and kubectl are installed.
# Run from the project repository: bash bootstrap.sh
# Stop on a failed command, unset variable, or failed pipeline.
set -euo pipefail

# Show the start time.
echo "Bootstrap starting..."

# Project variables
STUDENT_ID="101753267"
NAMESPACE="mysql-${STUDENT_ID}"
SECRET_NAME="mysql-secrets-${STUDENT_ID}"

# Task 10: Create the Docker-based Kubernetes nodes from kind-config.yaml.
kind create cluster --image kindest/node:v1.35.8 --config kind-config.yaml --wait 180s

# Continue only when all Kubernetes nodes are Ready (Week10 wait pattern).
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Display nodes and the kind-provided storage provisioner.
kubectl get nodes -o wide
kubectl get storageclass standard

########################################################
# Tasks 1 and 7 - Namespace and Secret
########################################################

# Replace literal ${NAMESPACE} and ${SECRET_NAME} in each manifest file.
# The backslash keeps the search text literal; the replacement uses our variable.
# Replace only the project-specific placeholders
sed -i "s/\${NAMESPACE}/$NAMESPACE/g" manifests/*.yaml
sed -i "s/\${SECRET_NAME}/$SECRET_NAME/g" manifests/*.yaml

# Create the Namespace before creating the Secret
kubectl apply -f manifests/00-namespace.yaml

# Create random passwords at deployment time.
kubectl create secret generic "$SECRET_NAME" \
  -n "$NAMESPACE" \
  --from-literal=root-password="$(openssl rand -hex 16)" \
  --from-literal=replication-password="$(openssl rand -hex 16)" \
  --dry-run=client -o yaml | kubectl apply -f -

# Apply the numbered ConfigMap, Services and StatefulSet after the Secret exists.
kubectl apply -f manifests/

########################################################
# Task 4 - Prepare the initial primary for mysqldump and replication
########################################################
# Wait only for mysql-0: replicas cannot clone until the account below exists.
kubectl wait --for=create pod/mysql-0 -n "$NAMESPACE" --timeout=60s
kubectl wait --for=condition=Ready pod/mysql-0 -n "$NAMESPACE" --timeout=300s

# Send ordinary SQL into the running Pod (same exec pattern as seeding below).
# BASH is quoted so both password variables expand inside the container.
# Account SQL is adapted from the MySQL manual, not the Kubernetes tutorial.
kubectl exec -i mysql-0 -n "$NAMESPACE" -c mysql -- bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS clo835;
CREATE USER 'repl'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
GRANT REPLICATION SLAVE, REPLICATION CLIENT, RELOAD ON *.* TO 'repl'@'%';
GRANT SELECT, SHOW VIEW, TRIGGER ON clo835.* TO 'repl'@'%';
SQL
BASH

########################################################
# Task 10 - Wait for the MySQL StatefulSet
########################################################
kubectl rollout status statefulset/mysql -n "$NAMESPACE" --timeout=300s
kubectl get pods,pvc -n "$NAMESPACE"

########################################################
# Task 4 - Display Replication Status
########################################################
# Check replication on both replicas
kubectl exec mysql-1 -n "$NAMESPACE" -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
kubectl exec mysql-2 -n "$NAMESPACE" -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'

# Task 8: Send SQL through standard input (-i) to the mysql container (-c).
# Single quotes keep MYSQL_ROOT_PASSWORD for the container to expand.
# Unquoted SQL below lets this host expand STUDENT_ID.
# AUTO_INCREMENT supplies IDs; the timestamp defaults to the insertion time.
# Create the database, table and five initial rows
kubectl exec -i mysql-0 -n "$NAMESPACE" -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<SQL
CREATE DATABASE IF NOT EXISTS clo835;
USE clo835;

CREATE TABLE IF NOT EXISTS students (
  seq BIGINT AUTO_INCREMENT PRIMARY KEY,
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
# wait until mysql-2 has received all five seed rows
# Project check using the until loop pattern from the labs
until kubectl exec mysql-2 -n "$NAMESPACE" -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM clo835.students WHERE seq BETWEEN 1 AND 5;"' | grep -qx '5'; do
  sleep 2
done

# Print the replicated rows as deployment evidence.
kubectl exec mysql-2 -n "$NAMESPACE" -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table -e "SELECT seq, student_id, created_at FROM clo835.students ORDER BY seq;"'

# Show the complete time.
echo "Bootstrap completed in $SECONDS seconds."