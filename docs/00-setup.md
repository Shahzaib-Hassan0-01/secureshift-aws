# \# Phase 0: Account setup and cost controls

# 

# \## Goal

# Secure the account and make sure I can't burn through the AWS credits without noticing, before building anything.

# 

# \## What I set up

# 1\. Built in a shared AWS account using my own IAM user with `AdministratorAccess`, not the root user.

# 2\. MFA enabled on my IAM user (virtual authenticator app).

# 3\. AWS Budget `secureshift-monthly`: $50 per month, with \*\*credits excluded\*\* so it tracks real usage instead of showing $0.

# 4\. Email alerts verified for the budget.

# 5\. Credits checked: $179 remaining, valid until September 2027.

# 

# \## Screenshots

# !\[IAM user with MFA](screenshots/00-setup/01-iam-user-mfa.png)

# !\[Budget with alerts](screenshots/00-setup/02-budget-alerts.png)

# 

# \## Problems I hit and how I fixed them

# \- \*\*Budget showed the wrong costs:\*\* with credits included, the budget would always show $0 and never alert. In the new Budgets console, the charge-type option has moved under \*Scope → Filter specific AWS cost dimensions\*. I excluded \*\*Credit\*\* there.

# \- \*\*Alerts weren't active:\*\* the budget showed "0/1 email verified" until I confirmed the AWS Notifications email.

# 

# \## What I'd change in production

# \- Use AWS Organizations with a separate account per environment, and IAM Identity Center instead of IAM users.

# \- Add Cost Anomaly Detection and a budget action that blocks new resources at 100%.

# 

# \## Cost

# $0 for this phase.

