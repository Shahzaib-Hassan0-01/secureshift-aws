# SecureShift on AWS

An incident-reporting app for security officers, built on AWS in three phases:
a highly available web app, a serverless event-driven pipeline, and a cross-Region disaster recovery design.

> Status: in progress (started October 2026)

## Architecture

_Diagram coming soon: `diagrams/architecture.png`_

## Phases

| # | Phase | AWS services | Write-up |
|---|---|---|---|
| 0 | Account setup and cost controls | IAM, Budgets, MFA | [docs/00-setup.md](docs/00-setup.md) |
| 1 | Highly available web app | VPC, ALB, EC2 Auto Scaling, RDS, Secrets Manager | [docs/01-ha-web-app.md](docs/01-ha-web-app.md) |
| 2 | Serverless, event-driven | S3, SQS, Lambda, DynamoDB, SNS | [docs/02-serverless.md](docs/02-serverless.md) |
| 3 | Disaster recovery | AWS Backup, CloudFront origin failover, pilot light | [docs/03-disaster-recovery.md](docs/03-disaster-recovery.md) |

Also: [DR runbook](docs/dr-runbook.md) · [Security review](docs/security-review.md) · [Cost report](docs/cost-report.md)

## What I learned

_To be written at the end._

## Cost

Built on AWS Free Tier credits. Resources are deleted after every build session. Full breakdown in the [cost report](docs/cost-report.md).
