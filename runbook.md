# Runbook

Run all commands in the EC2 project folder. Use terminal A for Writer and terminal B for checks and recovery. Keep terminal B connected during failover timing.

## 1. Check replication

In terminal B, check both replicas:

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"' | grep -E 'Source_Host:|Relay_Source_Log_File:|Exec_Source_Log_Pos:|Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:'
kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"' | grep -E 'Source_Host:|Relay_Source_Log_File:|Exec_Source_Log_Pos:|Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:'
```

Healthy replication has both threads Yes, lag returning to 0, and empty Last_IO_Error and Last_SQL_Error fields.

## 2. Start Writer and check data

In terminal A, start Writer:

```bash
./writer.sh mysql-0 2>&1 | grep -vF 'mysql: [Warning] Using a password on the command line interface can be insecure.'
```

Leave Writer running; Ctrl+C stops it. In terminal B, check the last confirmed ID and the current data:

```bash
tail -n 1 writer-ack.log
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
```

## 3. Replica failure

In terminal B, record mysql-1's Pod IP, age and PVC/PV before deletion:

```bash
kubectl get pod mysql-1 -n mysql-101753267 -o wide
kubectl get pvc data-mysql-1 -n mysql-101753267
```

Delete only the Pod, wait for recovery, then check its storage and replication:

```bash
kubectl delete pod mysql-1 -n mysql-101753267
kubectl wait --for=condition=Ready pod/mysql-1 -n mysql-101753267 --timeout=180s
kubectl get pod mysql-1 -n mysql-101753267 -o wide
kubectl get pvc data-mysql-1 -n mysql-101753267
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"' | grep -E 'Source_Host:|Relay_Source_Log_File:|Exec_Source_Log_Pos:|Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:'
```
The StatefulSet recreates the Pod using the same PVC/PV. Expect healthy replication. Pause Writer and compare mysql-0 and mysql-1 using the query in section 2 to confirm catch-up. Restart Writer before section 4. To test mysql-2, use mysql-2 and data-mysql-2.

## 4. Primary failure and promotion

In terminal B, start the timer and delete mysql-0:

```bash
FAILOVER_START=$SECONDS
kubectl delete pod mysql-0 -n mysql-101753267
```

Stop Writer in terminal A if it has not exited. Keep it stopped until section 5. In terminal B, wait for mysql-0 and make it read-only:

```bash
tail -n 1 writer-ack.log
kubectl wait --for=condition=Ready pod/mysql-0 -n mysql-101753267 --timeout=180s
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -h 127.0.0.1 -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SET PERSIST super_read_only=ON; SELECT @@read_only, @@super_read_only; SHOW MASTER STATUS;"'
```

Both read-only values must be 1. This procedure requires mysql-0 to recover using its existing PVC. Compare both replicas before promotion:

```bash
tail -n 1 writer-ack.log
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students; SHOW REPLICA STATUS\G"' | grep -E '^MAX|^[0-9]|Relay_Source_Log_File:|Exec_Source_Log_Pos:|Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:'
kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students; SHOW REPLICA STATUS\G"' | grep -E '^MAX|^[0-9]|Relay_Source_Log_File:|Exec_Source_Log_Pos:|Replica_IO_Running:|Replica_SQL_Running:|Last_IO_Error:|Last_SQL_Error:'
```
Both replicas must match mysql-0's File/Position, with both threads Yes and no errors. Compare MAX(seq) and COUNT(*). Keep Writer stopped; verify every acknowledged ID in section 5 before resuming writes.

Promote mysql-1 and expect read-only values 0 / 0. If choosing mysql-2, swap mysql-1 and mysql-2 in the remaining commands and Writer target:

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF; SELECT @@read_only, @@super_read_only;"'
```

Create the replication account on mysql-1 and read its new File and Position:

```bash
kubectl exec -i mysql-1 -n mysql-101753267 -c mysql -- bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER 'repl'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
SHOW MASTER STATUS;
SQL
BASH
```

In terminal B, enter the new File and Position once. Keep Writer stopped and use this terminal for the following commands:

```bash
read -r -p "New primary File: " LOG_FILE
read -r -p "New primary Position: " LOG_POS
printf 'Using %s at %s\n' "$LOG_FILE" "$LOG_POS"
```

Point mysql-2 and then mysql-0 to the new primary:

```bash
kubectl exec -i mysql-2 -n mysql-101753267 -c mysql -- env LOG_FILE="$LOG_FILE" LOG_POS="$LOG_POS" bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
STOP REPLICA;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-1.mysql-h',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='${REPLICATION_PASSWORD}',
  SOURCE_LOG_FILE='${LOG_FILE}',
  SOURCE_LOG_POS=${LOG_POS},
  SOURCE_CONNECT_RETRY=10,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
BASH

kubectl exec -i mysql-0 -n mysql-101753267 -c mysql -- env LOG_FILE="$LOG_FILE" LOG_POS="$LOG_POS" bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-1.mysql-h',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='${REPLICATION_PASSWORD}',
  SOURCE_LOG_FILE='${LOG_FILE}',
  SOURCE_LOG_POS=${LOG_POS},
  SOURCE_CONNECT_RETRY=10,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
BASH
```

Check both replicas. Expect source mysql-1.mysql-h, both threads Yes, lag 0 and empty error fields:

```bash
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"' | grep -E 'Source_Host:|Relay_Source_Log_File:|Exec_Source_Log_Pos:|Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:'
kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"' | grep -E 'Source_Host:|Relay_Source_Log_File:|Exec_Source_Log_Pos:|Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:'
```

## 5. Verify data and resume writes

With Writer stopped, compare its confirmed IDs and student IDs with the new primary:

```bash
cat writer-ack.log
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table -e "SELECT seq, student_id FROM clo835.students ORDER BY seq; SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
```

Compare the last confirmed ID with MAX(seq) and COUNT(*), including the five seed rows. Verify every acknowledged ID; matching MAX alone is insufficient. Unused AUTO_INCREMENT IDs and committed writes without a client reply may explain gaps.

After verification, restart Writer on mysql-1 in terminal A:

```bash
./writer.sh mysql-1 2>&1 | grep -vF 'mysql: [Warning] Using a password on the command line interface can be insecure.'
```

After the first successful write, immediately record the confirmation time in the original terminal B:

```bash
tail -n 1 writer-ack.log
echo "Failover confirmed in $((SECONDS - FAILOVER_START)) seconds."
```

Recovery must take no more than 10 minutes from the kill to a successful new-primary write. This timer records when you confirm it. If terminal B reconnects, its timer is lost.

Stop Writer with Ctrl+C in terminal A. In terminal B, verify the new writes:

```bash
cat writer-ack.log
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table -e "SELECT seq, student_id FROM clo835.students ORDER BY seq; SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
```

Check that every confirmed ID and student ID appears in the table. Save the commands and output.

## 6. Rebuild — only if needed

Stop Writer and save the evidence. Archive the old log using an unused number. If asked to overwrite, answer n and choose another number. Skip this command if writer-ack.log does not exist:

```bash
mv -i writer-ack.log writer-ack-1.log
```

Delete the cluster and all database data, then rebuild. Bootstrap prints its elapsed time:

```bash
kind delete cluster --name kind
./bootstrap.sh
```

After rebuilding, expect three Ready MySQL Pods, three Bound PVCs and five seed rows on mysql-2. Repeat section 1 to check replication.
