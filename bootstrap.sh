#!/bin/bash
# CLO835 Final Project
# Run on the EC2 Host after Docker, kind and kubectl are installed.
# Run from the project repository: bash bootstrap.sh
set -euo pipefail

# Eviornment Variables
STUDENT_ID="101753267"
NAMESPACE="mysql-${STUDENT_ID}"
SECRET_NAME="mysql-secrets-${STUDENT_ID}"

# Enter the dirtctory containing the project manifest
cd "$(dirname "${BASH_SOURCE[0]}")"

# Create 1 control-plane node and 2 worker nodes
kind create cluster --config kind-config.yaml --wait 180s

# Wait for all nodes to be ready
kubectl wait --for=condition=Ready nodes --all --timeout=180s

# Display node status and the required StorageClass
kubectl get nodes -o wide
kubectl get storageclass standard

# Make a dirctory for manifests
mkdir -p manifests

########################################################
# Task 1 - Namespace
########################################################
# Generate the Namespace manifest using the Student ID
cat > manifests/namespace.yaml <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${NAMESPACE}
EOF

########################################################
# Task 5 - Headless and Read Services
########################################################
# Generate the headless and read Services manifests
cat > manifests/mysql-services.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: mysql-h
  namespace: ${NAMESPACE}
spec:
  clusterIP: None
  selector: {app: mysql}
  ports:
    - {port: 3306, targetPort: 3306}
---
apiVersion: v1
kind: Service
metadata:
  name: mysql-read
  namespace: ${NAMESPACE}
spec:
  selector: {app: mysql}
  ports:
    - {port: 3306, targetPort: 3306}
EOF

########################################################
# Tasks 2 and 6 - MySQL StatefulSet and PVCs
########################################################
# MySQL StatefulSet with 3 replicas using mysql:8.0
# One PVC per Pod, standard StorageClass, at least 1Gi
cat > manifests/mysql-statefulset.yaml <<EOF
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
  namespace: ${NAMESPACE}
spec:
  serviceName: mysql-h
  replicas: 3
  selector:
    matchLabels: {app: mysql}
  template:
    metadata:
      labels: {app: mysql}
    spec:
      containers:
      - name: mysql
        image: mysql:8.0
        env:
        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: ${SECRET_NAME}
              key: root-password
        ports:
        - {name: mysql, containerPort: 3306}
        volumeMounts:
        - {name: data, mountPath: /var/lib/mysql}
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: [ReadWriteOnce]
      storageClassName: standard
      resources: {requests: {storage: 1Gi}}
EOF

########################################################
# Task 7 - Secret
########################################################
# Read passwords from local files
mkdir -p secrets

# Generate password files only when they do not exist
if [ ! -f secrets/password.txt ]; then
  cat /proc/sys/kernel/random/uuid > secrets/password.txt
fi

chmod 700 secrets
chmod 600 secrets/password.txt

ROOT_PASSWORD=$(cat secrets/password.txt)
REPLICATION_PASSWORD="$ROOT_PASSWORD"

# Generate the Kubernetes Secret manifest
cat > manifests/mysql-secrets.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
type: Opaque
stringData:
  root-password: "${ROOT_PASSWORD}"
  replication-password: "${REPLICATION_PASSWORD}"
EOF

chmod 600 manifests/mysql-secrets.yaml

########################################################
# Task 7 - ConfigMap
########################################################
# Store MySQL configuration in a ConfigMap
cat > manifests/mysql-configmap.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: mysql-config
  namespace: ${NAMESPACE}
data:
  mysql.cnf: |
    [mysqld]
    log-bin=mysql-bin
    binlog-format=ROW
    log-replica-updates=ON
EOF