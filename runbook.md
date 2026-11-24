# Runbook

Run in the EC2 project folder. Terminal A: Writer. Terminal B: other commands.

## 1. Check replication

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
```

Healthy: Replica_IO_Running and Replica_SQL_Running are Yes; Seconds_Behind_Source returns to 0; Last_IO_Error and Last_SQL_Error are empty.

## 2. Start Writer and check data

Terminal A:

```bash
./writer.sh mysql-0
```

Leave it running. Ctrl+C stops it. Terminal B:

```bash
tail -n 1 writer-ack.log
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
```

## 3. Replica failure

Before the kill:

```bash
kubectl get pod mysql-1 -n mysql-101753267 -o wide
kubectl get pvc data-mysql-1 -n mysql-101753267
```

Delete only the Pod.

```bash
kubectl delete pod mysql-1 -n mysql-101753267
kubectl wait --for=condition=Ready pod/mysql-1 -n mysql-101753267 --timeout=180s
kubectl get pod mysql-1 -n mysql-101753267 -o wide
kubectl get pvc data-mysql-1 -n mysql-101753267
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
```
Expect the same PVC/PV and healthy replication. To confirm catch-up, pause Writer and compare the mysql-0 and mysql-1 counts using the query in section 2. Restart Writer before a primary-failure rehearsal. For a mysql-2 failure, use mysql-2 and data-mysql-2.

## 4. Primary failure and promotion

Record the kill time. Delete mysql-0 only for rehearsal; if the instructor already deleted it, do not delete it again. 

```bash
FAILOVER_START=$SECONDS
kubectl delete pod mysql-0 -n mysql-101753267 --wait=false
```

Stop Writer in terminal A if it has not exited. Keep it stopped until section 5. In terminal B:

```bash
tail -n 1 writer-ack.log
kubectl wait --for=condition=Ready pod/mysql-0 -n mysql-101753267 --timeout=180s
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SET PERSIST super_read_only=ON; SELECT @@read_only, @@super_read_only; SHOW MASTER STATUS;"'
```

Both read-only values must be 1. This procedure requires mysql-0 to recover with its existing PVC. Check both replicas before promotion:

```bash
tail -n 1 writer-ack.log
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT seq, student_id FROM clo835.students ORDER BY seq; SHOW REPLICA STATUS\G"'
kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT seq, student_id FROM clo835.students ORDER BY seq; SHOW REPLICA STATUS\G"'
```
Compare Relay_Source_Log_File and Exec_Source_Log_Pos with mysql-0's SHOW MASTER STATUS. Select a caught-up replica containing every acknowledged row; stop if data is missing. 

Promote mysql-1; If choosing mysql-2, swap mysql-1/mysql-2 in the remaining commands and Writer target; expect read-only values 0 / 0:

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "STOP REPLICA; RESET REPLICA ALL; SET PERSIST super_read_only=OFF; SET PERSIST read_only=OFF; SELECT @@read_only, @@super_read_only;"'
```

Create its replication account and read its NEW log position:

```bash
kubectl exec -i mysql-1 -n mysql-101753267 -c mysql -- bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CREATE USER 'repl'@'%' IDENTIFIED BY '${REPLICATION_PASSWORD}';
GRANT REPLICATION SLAVE ON *.* TO 'repl'@'%';
SHOW MASTER STATUS;
SQL
BASH
```

Replace <FILE> and <POSITION> in BOTH blocks below with that output. First repoint mysql-2, then mysql-0:

```bash
kubectl exec -i mysql-2 -n mysql-101753267 -c mysql -- bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
STOP REPLICA;
RESET REPLICA ALL;
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-1.mysql-h',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='${REPLICATION_PASSWORD}',
  SOURCE_LOG_FILE='<FILE>',
  SOURCE_LOG_POS=<POSITION>,
  SOURCE_CONNECT_RETRY=10,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
BASH

kubectl exec -i mysql-0 -n mysql-101753267 -c mysql -- bash <<'BASH'
mysql -uroot -p"$MYSQL_ROOT_PASSWORD" <<SQL
CHANGE REPLICATION SOURCE TO
  SOURCE_HOST='mysql-1.mysql-h',
  SOURCE_USER='repl',
  SOURCE_PASSWORD='${REPLICATION_PASSWORD}',
  SOURCE_LOG_FILE='<FILE>',
  SOURCE_LOG_POS=<POSITION>,
  SOURCE_CONNECT_RETRY=10,
  GET_SOURCE_PUBLIC_KEY=1;
START REPLICA;
SQL
BASH
```

Check both; expect source mysql-1.mysql-h, both threads Yes, lag 0, no errors:

```bash
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
kubectl exec mysql-2 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
```

## 5. Verify data and resume writes

With Writer stopped, check if every confirmed ID/student exist:

```bash
cat writer-ack.log
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table -e "SELECT seq, student_id FROM clo835.students ORDER BY seq; SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
```

Compare the last confirmed ID with MAX(seq) and COUNT(*), including the five seed rows. Verify every acknowledged ID; matching MAX alone is insufficient. Unused AUTO_INCREMENT IDs and committed writes without a client reply may explain gaps.

After verification, terminal A:

```bash
./writer.sh mysql-1
```

After its first successful write, terminal B:

```bash
tail -n 1 writer-ack.log
echo "Failover confirmed in $((SECONDS - FAILOVER_START)) seconds."
```

Recovery must take no more than 10 minutes from the kill to a successful new-primary write. Stop Writer, then repeat the data check above to include resumed writes in the evidence.

## 6. Rebuild — only if needed

Stop Writer and save the previous evidence. If its log exists, archive it:

```bash
mv writer-ack.log "writer-$(date +%Y%m%d-%H%M%S).log"
```

Delete the cluster and ALL database data, then rebuild. Bootstrap prints its start and finish times:

```bash
kind delete cluster --name kind
./bootstrap.sh
```

After rebuilding, expect three Ready MySQL Pods, three Bound PVCs and five seed rows on mysql-2. Repeat section 1 to check replication.
