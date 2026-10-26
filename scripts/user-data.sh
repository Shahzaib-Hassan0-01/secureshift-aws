#!/bin/bash
# SecureShift web server bootstrap (EC2 user data, Amazon Linux 2023)
# Replace the two REPLACE_ME values below before pasting into the launch template.
set -euxo pipefail

DB_ENDPOINT="REPLACE_ME_DB_ENDPOINT"
DB_SECRET_ARN="REPLACE_ME_DB_SECRET_ARN"

dnf install -y python3-pip
mkdir -p /opt/secureshift
python3 -m venv /opt/secureshift/venv

cat > /opt/secureshift/requirements.txt <<'REQEOF'
flask==3.0.3
gunicorn==22.0.0
pymysql==1.1.1
cryptography
boto3
REQEOF
/opt/secureshift/venv/bin/pip install -r /opt/secureshift/requirements.txt

cat > /opt/secureshift/app.py <<'APPEOF'
"""SecureShift web app.

Security officers report incidents through a web form:
  - the report details are stored in RDS MySQL
  - the photo is uploaded to S3 under incidents/, which starts the Phase 2
    serverless pipeline (SQS -> Lambda -> DynamoDB + SNS email alert)

Every page shows which EC2 instance and Availability Zone served it, so the
load balancer spreading traffic across AZs is visible.
"""

import json
import os
import urllib.request
import uuid
from datetime import datetime, timezone

import boto3
import pymysql
from flask import Flask, redirect, render_template_string, request, url_for
from werkzeug.utils import secure_filename

REGION = os.environ.get("AWS_REGION", "eu-west-1")
BUCKET = os.environ["PHOTO_BUCKET"]
DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ.get("DB_NAME", "secureshift")
DB_SECRET_ARN = os.environ["DB_SECRET_ARN"]
ALLOWED_TYPES = {"image/jpeg", "image/png"}

app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024  # 5 MB upload limit

s3 = boto3.client("s3", region_name=REGION)
secrets = boto3.client("secretsmanager", region_name=REGION)
_db_credentials = None


def instance_info():
    """Read the instance ID and AZ from the metadata service (IMDSv2)."""
    try:
        token_request = urllib.request.Request(
            "http://169.254.169.254/latest/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
        )
        token = urllib.request.urlopen(token_request, timeout=1).read().decode()

        def get(path):
            req = urllib.request.Request(
                f"http://169.254.169.254/latest/meta-data/{path}",
                headers={"X-aws-ec2-metadata-token": token},
            )
            return urllib.request.urlopen(req, timeout=1).read().decode()

        return get("instance-id"), get("placement/availability-zone")
    except Exception:
        return "unknown", "unknown"


def db_credentials():
    """Fetch the RDS-managed username and password from Secrets Manager once."""
    global _db_credentials
    if _db_credentials is None:
        secret = secrets.get_secret_value(SecretId=DB_SECRET_ARN)
        _db_credentials = json.loads(secret["SecretString"])
    return _db_credentials


def db_connection():
    creds = db_credentials()
    return pymysql.connect(
        host=DB_HOST,
        user=creds["username"],
        password=creds["password"],
        database=DB_NAME,
        connect_timeout=5,
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


def create_table():
    with db_connection() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS incidents (
                id CHAR(36) PRIMARY KEY,
                officer VARCHAR(100) NOT NULL,
                location VARCHAR(200) NOT NULL,
                description TEXT NOT NULL,
                photo_key VARCHAR(500),
                reported_at DATETIME NOT NULL
            )
            """
        )


PAGE = """
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>SecureShift</title>
  <style>
    body { font-family: system-ui, sans-serif; max-width: 760px; margin: 2rem auto; padding: 0 1rem; color: #1f2933; }
    h1 { margin-bottom: 0.2rem; }
    .served { background: #eef2f7; padding: 0.6rem 0.8rem; border-radius: 6px; font-size: 0.9rem; }
    form { display: grid; gap: 0.6rem; margin: 1.5rem 0; }
    input, textarea, button { font: inherit; padding: 0.5rem; }
    button { background: #1f6feb; color: #fff; border: 0; border-radius: 6px; cursor: pointer; }
    table { width: 100%; border-collapse: collapse; font-size: 0.9rem; }
    th, td { text-align: left; padding: 0.4rem; border-bottom: 1px solid #d9dee5; }
    .msg { padding: 0.6rem 0.8rem; border-radius: 6px; background: #e6f4ea; }
    .err { background: #fdecea; }
  </style>
</head>
<body>
  <h1>SecureShift</h1>
  <p>Incident reporting for security officers.</p>
  <p class="served">Served by <strong>{{ instance_id }}</strong> in <strong>{{ az }}</strong></p>

  {% if message %}<p class="msg {{ 'err' if error else '' }}">{{ message }}</p>{% endif %}

  <form method="post" action="{{ url_for('report') }}" enctype="multipart/form-data">
    <input name="officer" placeholder="Officer name" required maxlength="100">
    <input name="location" placeholder="Location (e.g. Front gate)" required maxlength="200">
    <textarea name="description" placeholder="What happened?" required rows="4"></textarea>
    <label>Photo (JPEG or PNG, max 5 MB) <input type="file" name="photo" accept="image/jpeg,image/png" required></label>
    <button type="submit">Report incident</button>
  </form>

  <h2>Recent incidents</h2>
  {% if incidents %}
  <table>
    <tr><th>Reported (UTC)</th><th>Officer</th><th>Location</th><th>Description</th></tr>
    {% for i in incidents %}
    <tr><td>{{ i.reported_at }}</td><td>{{ i.officer }}</td><td>{{ i.location }}</td><td>{{ i.description }}</td></tr>
    {% endfor %}
  </table>
  {% else %}
  <p>No incidents reported yet.</p>
  {% endif %}
</body>
</html>
"""


@app.get("/health")
def health():
    """Load balancer health check: the web server is up."""
    return "ok", 200


@app.get("/")
def index():
    instance_id, az = instance_info()
    message = request.args.get("message")
    error = request.args.get("error") == "1"
    incidents = []
    try:
        with db_connection() as conn, conn.cursor() as cur:
            cur.execute(
                "SELECT reported_at, officer, location, description "
                "FROM incidents ORDER BY reported_at DESC LIMIT 10"
            )
            incidents = cur.fetchall()
    except Exception as exc:
        app.logger.error("Database read failed: %s", exc)
        message, error = "Database is unavailable right now.", True
    return render_template_string(
        PAGE, instance_id=instance_id, az=az, incidents=incidents, message=message, error=error
    )


@app.post("/report")
def report():
    photo = request.files.get("photo")
    officer = request.form.get("officer", "").strip()
    location = request.form.get("location", "").strip()
    description = request.form.get("description", "").strip()

    if not (officer and location and description and photo and photo.filename):
        return redirect(url_for("index", message="Please fill in every field.", error=1))
    if photo.mimetype not in ALLOWED_TYPES:
        return redirect(url_for("index", message="Photo must be JPEG or PNG.", error=1))

    incident_id = str(uuid.uuid4())
    filename = secure_filename(photo.filename) or "photo"
    photo_key = f"incidents/{incident_id}-{filename}"

    try:
        s3.upload_fileobj(photo, BUCKET, photo_key, ExtraArgs={"ContentType": photo.mimetype})
        with db_connection() as conn, conn.cursor() as cur:
            cur.execute(
                "INSERT INTO incidents (id, officer, location, description, photo_key, reported_at) "
                "VALUES (%s, %s, %s, %s, %s, %s)",
                (incident_id, officer, location, description, photo_key,
                 datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")),
            )
    except Exception as exc:
        app.logger.error("Report failed: %s", exc)
        return redirect(url_for("index", message="Could not save the report. Try again.", error=1))

    return redirect(url_for("index", message="Incident reported. The supervisor has been alerted."))


try:
    create_table()
except Exception as exc:  # the app still starts; the page shows the DB error
    app.logger.error("Could not create table: %s", exc)
APPEOF

cat > /etc/secureshift.env <<ENVEOF
AWS_REGION=eu-west-1
PHOTO_BUCKET=secureshift-incident-photos
DB_HOST=$DB_ENDPOINT
DB_NAME=secureshift
DB_SECRET_ARN=$DB_SECRET_ARN
ENVEOF
chmod 600 /etc/secureshift.env

cat > /etc/systemd/system/secureshift.service <<'SVCEOF'
[Unit]
Description=SecureShift web app
After=network-online.target
Wants=network-online.target

[Service]
User=ec2-user
WorkingDirectory=/opt/secureshift
EnvironmentFile=/etc/secureshift.env
ExecStart=/opt/secureshift/venv/bin/gunicorn --workers 2 --bind 0.0.0.0:80 --access-logfile - app:app
AmbientCapabilities=CAP_NET_BIND_SERVICE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
SVCEOF

chown -R ec2-user:ec2-user /opt/secureshift
systemctl daemon-reload
systemctl enable --now secureshift
