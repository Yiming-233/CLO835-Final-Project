# CLO835 Final Project

Student ID: 101753267

This project runs three MySQL Pods in a kind cluster on one EC2 instance. Initially, mysql-0 is the primary, and mysql-1 and mysql-2 are replicas. Each Pod has its own persistent storage.

## Run Bootstrap

On the EC2 host, prepare Docker, kind, kubectl and OpenSSL. From a fresh project folder with no existing kind cluster, run:

```bash
git clone https://github.com/Yiming-233/CLO835-Final-Project.git
cd CLO835-Final-Project
```

Run the bootstrap:
```bash
./bootstrap.sh
```

The script creates the cluster, deploys MySQL, inserts five initial rows and checks replication on mysql-2.

See [runbook.md](runbook.md) for detailed commands and recovery procedures.

## Sources

- CLO835 Week02, Week07, Week10, Week12 and Week14 labs
- Assignment 1
- [kind installation](https://kind.sigs.k8s.io/docs/user/quick-start/#installing-from-release-binaries)
- [MySQL mysqldump](https://dev.mysql.com/doc/refman/8.0/en/mysqldump.html)
- [MySQL replication setup](https://dev.mysql.com/doc/refman/8.0/en/change-replication-source-to.html)
- [Kubernetes replicated MySQL tutorial](https://kubernetes.io/docs/tasks/run-application/run-replicated-stateful-application/)

The tutorial was adapted to use MySQL 8.0 and mysqldump instead of MySQL 5.7 and XtraBackup.