# Restore a database backup

How to download a nightly backup and load it into PostgreSQL, for administrators recovering the
database or copying it elsewhere.

Each backup is a `pg_dump` custom-format archive. Its key is
`insights/{database}/{yyyy}/{mm}/{database}-{yyyyMMdd}T{HHmmss}Z.dump`, stamped in UTC.

## Before you start

- `pg_restore` 18 or newer, like the `pg_dump` that made the archive. PostgreSQL only promises
  that a newer `pg_restore` reads an older archive, not the reverse.
- Your own credentials for the bucket, allowed to list and read it. The deployment's key can only
  write.
- A database user allowed to create databases.

## Steps

1. List a month's backups and pick one. For MinIO or Ceph, add `--endpoint-url`.

   ```bash
   aws s3 ls s3://your-bucket/insights/vapor_database/2026/09/
   ```

2. Download it:

   ```bash
   aws s3 cp s3://your-bucket/insights/vapor_database/2026/09/vapor_database-20260924T020000Z.dump .
   ```

3. Check the archive reads cleanly. This lists its contents and restores nothing.

   ```bash
   pg_restore --list vapor_database-20260924T020000Z.dump
   ```

4. Stop the API, the queue worker and the scheduler, so nothing writes during the restore.
5. Restore into a new, empty database. `--no-owner` gives every table to the user you connect as.

   ```bash
   createdb --host=your-db-host --username=vapor_username vapor_restored
   pg_restore --host=your-db-host --username=vapor_username --dbname=vapor_restored \
     --no-owner --exit-on-error vapor_database-20260924T020000Z.dump
   ```

6. Swap the restored database in under the old name, keeping the old one aside:

   ```bash
   psql --host=your-db-host --username=vapor_username --dbname=postgres \
     -c 'ALTER DATABASE vapor_database RENAME TO vapor_database_old' \
     -c 'ALTER DATABASE vapor_restored RENAME TO vapor_database'
   ```

7. Start the three processes again. Nothing in their configuration changes.

## Check it worked

- `pg_restore` finishes with no error, and the renames print `ALTER DATABASE` twice.
- The API logs *Insights configured.* and serves the dashboard.
- The newest readings are from just before the backup's timestamp.

Once you are sure, drop `vapor_database_old` with `dropdb`.

#icicle-insights# #How-To# #Administrator#
