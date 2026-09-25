# Set up database backups

How to back up the database every night to S3-compatible object storage, for administrators who run
the deployment. [Architecture](../explanation/architecture.md#backups) explains how backups run.

## Before you start

- A bucket on AWS S3, MinIO, Ceph or another S3-compatible store.
- An access key for the deployment. It needs `s3:PutObject` under the backup prefix, `insights/`
  by default, and nothing else. Keys that read or delete backups belong to people.
- An image built from this change or later. It contains `pg_dump` 18.

## Steps

1. Give the access key only that permission. On AWS, as an IAM policy:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       { "Effect": "Allow", "Action": "s3:PutObject", "Resource": "arn:aws:s3:::your-bucket/insights/*" }
     ]
   }
   ```

2. Add a lifecycle rule that expires backups after the days you want to keep. Insights never
   deletes one. For MinIO or Ceph, add `--endpoint-url` with the store's address.

   ```bash
   aws s3api put-bucket-lifecycle-configuration --bucket your-bucket --lifecycle-configuration \
     '{"Rules":[{"ID":"expire-insights-backups","Status":"Enabled","Filter":{"Prefix":"insights/"},"Expiration":{"Days":30}}]}'
   ```

3. Set the variables on the queue worker and the scheduler. All of them are in
   [Configuration](../reference/configuration.md#database-backups).

   ```bash
   BACKUP_S3_ENDPOINT=https://s3.us-east-2.amazonaws.com
   BACKUP_S3_REGION=us-east-2
   BACKUP_S3_BUCKET=your-bucket
   BACKUP_S3_ACCESS_KEY_ID=the-access-key-id
   BACKUP_S3_SECRET_ACCESS_KEY=the-secret-access-key
   ```

   Leave `BACKUP_S3_PATH_STYLE` at `true` unless the store wants the bucket in the host name. If
   the store refuses encryption headers, set `BACKUP_S3_SSE=false`.

4. Restart the worker and the scheduler.
5. Take one backup now, from a shell in the worker's container:

   ```bash
   ./Insights backup-database
   ```

## Check it worked

- Each restarted process logs *Database backups configured.* with the endpoint, bucket and prefix.
- Step 5 prints *Uploaded … bytes to* and the object's key. A failure prints why and exits non-zero.
- After 02:00 UTC the worker logs *Database backup uploaded.* with `key` and `bytes`.
- A failed night alerts once as a warning, `backup_failed`, and shows in **Operations → Recent
  failures**.

To get a backup back, see [Restore a database backup](restore-a-database-backup.md).

#icicle-insights# #How-To# #Administrator#
