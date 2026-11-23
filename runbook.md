# Runbook

Run on EC2 in the project folder. Terminal A runs Writer; terminal B runs checks and recovery commands. Bootstrap, replica recovery, live primary promotion and acknowledged-row checks have been rehearsed.


## 1. Check replication

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'

kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
```

Expected: Replica_IO_Running and Replica_SQL_Running are Yes; Seconds_Behind_Source is close to 0; Last_IO_Error and Last_SQL_Error are empty.

## 2. Start Writer and check data

In terminal A:

```bash
./writer.sh
```

Keep Writer running. Use terminal B for the following commands.

Check the last confirmed write:

```bash
tail -n 1 writer-ack.log
```

Check the highest sequence and row count:

```bash
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students;"'

kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students;"'

kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
```

Results may differ temporarily while Writer runs.

## 3. Replica failure

### Before deletion

```bash
kubectl get pod mysql-1 -n mysql-101753267 -o wide
kubectl get pvc data-mysql-1 -n mysql-101753267
```

### Delete only the Pod and wait for recovery

```bash
kubectl delete pod mysql-1 -n mysql-101753267
kubectl wait --for=condition=Ready pod/mysql-1 -n mysql-101753267 --timeout=180s
```

### After recovery

```bash
kubectl get pod mysql-1 -n mysql-101753267 -o wide
kubectl get pvc data-mysql-1 -n mysql-101753267

kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
```

Expected: StatefulSet creates a new Pod using the same PVC/PV, and replication recovers. Do not delete the PVC. Keep Writer running. Use mysql-2/data-mysql-2 to test the other replica.

## 4. Primary promotion

Tested on 23 November 2026: mysql-0 failed during writes; mysql-1 accepted a new write after 4 minutes 7 seconds. Start from mysql-0 primary and mysql-1/mysql-2 replicas. Run commands in terminal B unless stated otherwise.

### Delete the primary while Writer runs in terminal A

For rehearsal, run:

```bash
date -Is
kubectl delete pod mysql-0 -n mysql-101753267 --wait=false
```

If the instructor already deleted the Pod, do not delete it again. Stop Writer in terminal A with Ctrl+C if it has not already exited. Record the last acknowledged write:

```bash
tail -n 1 writer-ack.log
```

### Keep the recreated old primary read-only

```bash
kubectl wait --for=condition=Ready pod/mysql-0 -n mysql-101753267 --timeout=180s
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SET PERSIST super_read_only=ON; SELECT @@read_only, @@super_read_only; SHOW MASTER STATUS;"'
```

Expected: 1 / 1. Keep Writer stopped. This tested procedure requires the old primary to recover with its existing PVC. Do not promote while it can still accept client writes.

### Compare replicas

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT seq, student_id FROM clo835.students ORDER BY seq; SHOW REPLICA STATUS\G"'
kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT seq, student_id FROM clo835.students ORDER BY seq; SHOW REPLICA STATUS\G"'
```

Check Relay_Source_Log_File and Exec_Source_Log_Pos against the old primary's file and position. Both replication threads should be Yes, with no errors. Every acknowledged row must be present. Select the most caught-up replica; below assumes mysql-1. Stop if acknowledged rows are missing.
### Promote mysql-1

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF; SELECT @@read_only, @@super_read_only;"'
```

Expected: 0 / 0. Create its replication account:

```bash
kubectl exec -i mysql-1 -n mysql-101753267 -c mysql -- bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER 'repl'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
SHOW MASTER STATUS;
SQL
BASH
```

Record the NEW file and position after account creation. Keep Writer stopped. The two blocks below use mysql-bin.000003 / 14820 from this rehearsal; replace BOTH with the current output for each new rehearsal.

### Point mysql-2 to mysql-1

```bash
kubectl exec -i mysql-2 -n mysql-101753267 -c mysql -- bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-1.mysql-h',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='${REPLICATION_PASSWORD}',
  SOURCE_LOG_FILE='mysql-bin.000003',
  SOURCE_LOG_POS=14820,
  SOURCE_CONNECT_RETRY=10,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
BASH
```

### Point mysql-0 to mysql-1

```bash
kubectl exec -i mysql-0 -n mysql-101753267 -c mysql -- bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-1.mysql-h',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='${REPLICATION_PASSWORD}',
  SOURCE_LOG_FILE='mysql-bin.000003',
  SOURCE_LOG_POS=14820,
  SOURCE_CONNECT_RETRY=10,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
BASH
```

### Check both replicas

```bash
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"' | grep -E 'Source_Host:|Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:'
kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"' | grep -E 'Source_Host:|Replica_IO_Running:|Replica_SQL_Running:|Seconds_Behind_Source:|Last_IO_Error:|Last_SQL_Error:'
```

Expected: source mysql-1.mysql-h, both threads Yes, lag 0, errors empty. Keep Writer stopped for section 5.
## 5. Verify no data loss

Keep Writer stopped. Run this section after promotion. This example assumes mysql-1 is the new primary. The rehearsal retained every acknowledged ID (6–50), with 50 total rows including five seed rows.

Check confirmed writes:

```bash
tail -n 1 writer-ack.log
cat writer-ack.log
```

Check the new primary:

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table -e "SELECT seq, student_id FROM clo835.students ORDER BY seq; SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
```

Every confirmed seq must exist in the database. MAX(seq) must not be below the last confirmed sequence. COUNT(*) includes five seed rows.

A matching maximum alone does not prove zero loss. AUTO_INCREMENT gaps can be unused IDs; a failed client response may still represent a committed write.

After verification passes, restart Writer in terminal A:

```bash
./writer.sh mysql-1
```

Record recovery time and confirm a new successful write in terminal B:

```bash
tail -n 1 writer-ack.log
date -Is
```

## 6. Rebuild

Stop Writer with Ctrl+C. These commands delete the cluster and all database data:

```bash
kind delete cluster --name kind
./bootstrap.sh
```

Before starting Writer again, rename the old writer-ack.log to keep different test runs separate.