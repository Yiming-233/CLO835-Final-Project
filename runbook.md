# Runbook
## 1. Check replication

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'

kubectl exec mysql-2 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
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
kubectl exec mysql-0 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students;"'

kubectl exec mysql-1 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students;"'

kubectl exec mysql-2 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
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
kubectl wait --for=condition=Ready pod/mysql-1 \
  -n mysql-101753267 --timeout=180s
```

### After recovery

```bash
kubectl get pod mysql-1 -n mysql-101753267 -o wide
kubectl get pvc data-mysql-1 -n mysql-101753267

kubectl exec mysql-1 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SHOW REPLICA STATUS\G"'
```

Expected: StatefulSet creates a new Pod using the same PVC/PV, and replication recovers. Do not delete the PVC. Keep Writer running. Use mysql-2/data-mysql-2 to test the other replica.

## 4. Primary promotion — not tested

### Stop Writer

After mysql-0 fails, press Ctrl+C in terminal A.

In terminal B, check the last acknowledged write:

```bash
tail -n 1 writer-ack.log
```

### Compare replicas

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students; SHOW REPLICA STATUS\G"'

kubectl exec mysql-2 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT MAX(seq), COUNT(*) FROM clo835.students; SHOW REPLICA STATUS\G"'
```

Select the most caught-up replica. Check applied source log positions and acknowledged rows, not only MAX(seq).

### Promote the selected replica

Before proceeding, the recreated mysql-0 must be prevented from accepting writes, and all acknowledged rows must be present on the candidate. These checks and the old-primary handling still need completion.

The following example assumes mysql-1 is selected.

Enter MySQL:

```bash
kubectl exec -it mysql-1 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'
```

At the mysql> prompt, run individually:

```sql
-- Stop replication from the old primary
STOP REPLICA;

-- Remove the old replication connection settings
RESET REPLICA ALL;

-- Allow writes
SET GLOBAL super_read_only = OFF;
SET GLOBAL read_only = OFF;

-- Both values should be 0
SELECT @@read_only, @@super_read_only;

exit
```

Keep Writer stopped for section 5.

Still required before this procedure is complete: handle mysql-0 safely, repoint the other replicas, preserve roles after restart, and test promotion and successful writes within 10 minutes.

## 5. Verify no data loss — not tested

Keep Writer stopped. Run this section only after promotion is complete. This example assumes mysql-1 is the new primary.

Check confirmed writes:

```bash
tail -n 1 writer-ack.log
cat writer-ack.log
```

Check the new primary:

```bash
kubectl exec mysql-1 -n mysql-101753267 -c mysql -- \
  sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" --table \
    -e "SELECT seq FROM clo835.students ORDER BY seq; SELECT MAX(seq), COUNT(*) FROM clo835.students;"'
```

Every confirmed seq must exist in the database. MAX(seq) must not be below the last confirmed sequence. COUNT(*) includes five seed rows.

A matching maximum alone does not prove zero loss. AUTO_INCREMENT gaps can be unused IDs; a failed client response may still represent a committed write.

After verification passes, restart Writer in terminal A:

```bash
./writer.sh mysql-1
```

Confirm a new successful write in terminal B:

```bash
tail -n 1 writer-ack.log
```

## 6. Rebuild

Stop Writer with Ctrl+C. These commands delete the cluster and all database data:

```bash
kind delete cluster --name kind
./bootstrap.sh
```

Before starting Writer again, rename the old writer-ack.log to keep different test runs separate.