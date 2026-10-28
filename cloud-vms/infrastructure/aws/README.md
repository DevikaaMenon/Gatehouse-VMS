# Deploying Cloud VMS on AWS

The same code runs on a laptop and in AWS; only configuration changes. Start small and add managed
services when you need them.

```
Cameras (RTSP) ──► EC2 worker(s) ──► RDS PostgreSQL   (metadata, events, counts)
      │               │  AI + tracking + rules
      │               └──────────────► S3 bucket       (recordings, evidence clips, snapshots)
      └──► MediaMTX (optional, raw live view)
Browser ──► ALB / EC2 API (FastAPI + React UI) ──► RDS, S3 (presigned links), Redis (live preview)
Logs: CloudWatch Logs (awslogs driver)
```

## 0. Free Tier deployment with Terraform (recommended)

`terraform/` builds the architecture above on one AWS account without leaving the Free Tier,
and `vms-aws.ps1` drives it from Windows PowerShell.

| Resource | Size | Free Tier allowance |
|---|---|---|
| EC2 (API + dashboard + AI workers in Docker) | `t3.micro`, CPU credits **standard**, 30 GB gp3 | 750 h/month, 30 GB EBS |
| RDS PostgreSQL 16 | `db.t4g.micro`, single-AZ, 20 GB gp2, private, 1-day backups | 750 h/month, 20 GB + 20 GB backup |
| S3 | evidence clips + snapshots only, expire after 30 days | 5 GB, 2,000 PUT, 20,000 GET |
| CloudWatch Logs | 7-day retention | 5 GB |
| SSM Parameter Store | 3 SecureString parameters (standard tier) | always free |
| AWS Budgets | $5/month incl. credits; emails at $1 used and if the month is forecast past $5 | 2 budgets free |

What keeps it free:

* **No** NAT gateway, load balancer, Elastic IP, ElastiCache, Secrets Manager, Multi-AZ or
  Performance Insights. Those are never free.
* The database has no public endpoint. A second public IPv4 address would go over the 750 free hours.
* `t3` instances default to *unlimited* CPU credits, which bill extra under sustained AI load.
  Here they are *standard*, so the CPU slows down instead of costing money.
* Only `evidence/` and `snapshots/` go to S3 (`VMS_S3_KEY_PREFIXES`). Thumbnails are rewritten every
  15 s and recordings are cut into 1-minute segments, so either one would use up the 2,000 free PUTs
  within days. They stay on the server disk, and recordings are kept for 2 days.
* The dashboard is open only to your IP address (`allowed_cidr`), over plain HTTP. HTTPS needs a
  domain plus a load balancer or reverse proxy, which is the next step.

**Limits of a t3.micro (1 GB RAM, 2 burstable vCPUs):** good for the dashboard, storage and database
parts, and for **one camera at a low analysis rate** (set *Frames analysed per second* to 1–2 when
adding the camera). Once its CPU credits are used up, the AI slows down considerably. For more cameras,
see *Compute* below, which is not free.

> **Which Free Tier do you have?** Accounts created before 15 July 2025 get the 12-month allowances
> in the table. Newer accounts are on the credit-based *Free plan*, where the same resources are paid
> for from your sign-up credits. In that case `.\vms-aws.ps1 stop` when you are not using it saves
> credits. Check *Billing → Free Tier* in the console either way.

### Steps (Windows)

```powershell
winget install Hashicorp.Terraform
winget install Amazon.AWSCLI
aws configure                    # access key of an IAM user (not the root account), region ap-south-1

cd cloud-vms\infrastructure\aws
copy terraform\terraform.tfvars.example terraform\terraform.tfvars   # then set alert_email in it
.\vms-aws.ps1 check
.\vms-aws.ps1 deploy             # shows the plan, type "yes"; ~10 min (the database is the slow part)
.\vms-aws.ps1 status             # the first build on the server takes another 20-40 min
.\vms-aws.ps1 password           # sign in as admin with this password
```

The server clones `repo_url` (default: this project on GitHub, branch `main`), so push your changes
there first, then `.\vms-aws.ps1 update` rebuilds the server from the latest commit. Other commands:
`logs [-Follow]`, `stop`, `start`, `destroy` (removes everything, including all videos and the database).
If your home IP changes, run `deploy` again to allow the new one.

### One-off demo (create, show, destroy)

1. **The day before:** `deploy`, wait until `status` shows *Health: OK*, sign in, add the camera at
   1–2 analysed frames per second and draw the lines/zones. **Leave it running.** A new t3.micro
   starts with no CPU credits (the first build is slow for this reason). While idle it builds up
   credits for about 2.4 hours of one full CPU, which is enough for the AI during the demo. Stopping
   it keeps those credits for 7 days.
2. **Before the demo:** `status` for the URL. On a different network (college Wi-Fi), run `deploy`
   again; it only updates the firewall rule to your new IP.
3. **Right after:** `destroy`. Nothing remains that could be billed. Videos, incidents and the
   database are deleted with it.

Shell access to the server, with no SSH port open:
`aws ssm start-session --target <instance_id>` (needs the Session Manager plugin). The first-boot log is
`/var/log/gatehouse-setup.log`.

The rest of this guide describes the same setup step by step in the AWS console, plus larger
options that are **not** free.

## 1. Storage and database

1. **S3**: create a private bucket, e.g. `rvce-vms-<yourname>`, in `ap-south-1` (Mumbai).
   Keep *Block all public access* on. Evidence is shared only through presigned URLs that expire
   after `VMS_MEDIA_URL_TTL_SECONDS` (15 minutes by default).
   Optional lifecycle rule: expire `recordings/` after 7 days (the app also deletes on its own).
2. **RDS PostgreSQL 16**: `db.t4g.micro` is enough for a project. Put it in the same VPC as the
   EC2 instance and allow port 5432 only from the instance's security group.
3. **IAM**: create a role for the EC2 instance with `iam-policy.json` from this folder (replace the
   bucket name). No access keys are needed on the instance.

## 2. Compute

| Workload | Instance | Notes |
|---|---|---|
| API + a few cameras (CPU) | `t3.large` / `c6i.xlarge` | Run the scaling benchmark first |
| Many cameras / bigger models | `g4dn.xlarge` (T4 GPU) | Build the image with the CUDA torch index |

Do not assume a GPU is needed: run `ml/evaluation/benchmark_scaling.py` on the instance type
you plan to use and keep the numbers for the report.

## 3. Run

```bash
# on the EC2 instance (Amazon Linux 2023 / Ubuntu) with Docker installed
git clone <your repo> && cd cloud-vms
docker build -f infrastructure/docker/Dockerfile -t cloud-vms .

cat > vms.env <<'EOF'
VMS_ENVIRONMENT=production
VMS_DATABASE_URL=postgresql+psycopg://vms:<password>@<rds-endpoint>:5432/vms
VMS_STORAGE_BACKEND=s3
VMS_S3_BUCKET=rvce-vms-<yourname>
VMS_S3_REGION=ap-south-1
VMS_SECRET_KEY=<64 random characters>
VMS_ADMIN_PASSWORD=<strong password>
VMS_TIMEZONE=Asia/Kolkata
VMS_CORS_ORIGINS=["https://<your-domain>"]
EOF

# single instance: API with embedded workers
docker run -d --name vms --restart unless-stopped --env-file vms.env -p 80:8000 \
  --log-driver=awslogs --log-opt awslogs-region=ap-south-1 --log-opt awslogs-group=/cloud-vms/api \
  --log-opt awslogs-create-group=true cloud-vms
```

### Scaling out

* Run the API with `VMS_EMBEDDED_WORKERS=false` and one or more worker containers:
  `docker run ... cloud-vms python -m app.workers.run --group gate-cameras`
* Give each camera a `worker_group` so each worker machine serves a known set of cameras.
* Add ElastiCache Redis and set `VMS_REDIS_URL` so live preview frames reach the API.
* Put the API behind an Application Load Balancer with HTTPS (ACM certificate).

### What is deliberately *not* used yet

* **SQS**: the queue between capture and inference is in-process and bounded (drops the oldest
  frame instead of growing). Moving event/evidence jobs to SQS is the next step once several
  machines must share work; the event engine is already idempotent (unique `dedup_key`), which
  SQS's at-least-once delivery requires.
* **Kinesis Video Streams**: not needed while cameras reach the worker over RTSP directly.

## 4. Security checklist

- [ ] Change the admin password on first login; create operator / viewer accounts per person.
- [ ] Camera passwords are stored encrypted (`camera_credentials_reference`), never shown in the UI
      or logs (URLs are redacted).
- [ ] Bucket not public; instance role scoped to one bucket.
- [ ] RDS reachable only from the app security group; automated backups on.
- [ ] HTTPS in front of the API; `VMS_CORS_ORIGINS` limited to your domain.
- [ ] Audit log (Users & audit page) reviewed periodically.
