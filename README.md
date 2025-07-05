# docker_pg_dump_auto

# postgres backup
5 3 * * * /opt/backup_pg/backup_postgres.sh >> /var/log/postgres_backup.log 2>&1
