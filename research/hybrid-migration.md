# Hybrid Migration: Add MCP to Superset 2.1.0

Run the MCP service (from master) alongside your existing 2.1.0 web server.
No full upgrade required. The web server keeps running; MCP runs as a new process.

> ✅ **Locally verified** against a 2.1.0 database. Login, dashboards, charts,
> SQL Lab, and RBAC all continue to work after the schema upgrade.

---

## What Happens

| Component | Before | After |
|-----------|--------|-------|
| Superset web server | 2.1.0 image | 2.1.0 image (unchanged) |
| Database schema | 2.1.0 schema | Upgraded to master (82 new migrations) |
| MCP service | — | New process from master image |

**One known breakage:** The `access_request` table is dropped by a migration.
The Security → Access Requests UI page in 2.1.0 will stop working.
All other features (dashboards, charts, SQL Lab, datasets, RBAC) are unaffected.

---

## Prerequisites

- PostgreSQL database backup taken
- Access to run commands inside the container / pod
- Google OAuth2 credentials (`GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET`)
- Master branch Docker image available (see [Building the Image](#building-the-image))

---

## Step 1 — Back Up the Database

```bash
pg_dump superset > superset_backup_$(date +%Y%m%d).sql
```

---

## Step 2 — Run Schema Migrations

Run these with the **master image** against your **production database**.

```bash
# Upgrade schema (82 new migrations)
superset db upgrade

# Sync new permissions into FAB tables (additive only, never removes existing rows)
# Required — without this, MCP permission checks fail at runtime
superset init
```

In Kubernetes, run as a one-off Job before deploying anything:

```bash
kubectl run superset-migrate --rm -it \
  --image=your-registry/superset:mcp-master \
  --restart=Never \
  --env="SUPERSET_CONFIG_PATH=/app/pythonpath/superset_config.py" \
  -- bash -c "superset db upgrade && superset init"
```

The 2.1.0 web server can keep serving traffic during this step — the schema
changes are additive and the 2.1.0 code ignores the new columns.

---

## Step 3 — Add Config for MCP Auth

Add this block to your `superset_config.py` (or equivalent ConfigMap):

```python
import logging
import os

logger = logging.getLogger(__name__)


def _mcp_google_auth_factory(app):
    client_id = os.environ.get("GOOGLE_CLIENT_ID")
    client_secret = os.environ.get("GOOGLE_CLIENT_SECRET")
    if not client_id or not client_secret:
        logger.warning("MCP GoogleProvider skipped: credentials not set")
        return None
    try:
        from fastmcp.server.auth.providers.google import GoogleProvider
        return GoogleProvider(
            client_id=client_id,
            client_secret=client_secret,
            # Public URL of the MCP service — browsers are redirected here for OAuth
            base_url=os.environ.get("MCP_BASE_URL", "https://mcp.yourcompany.com"),
            required_scopes=[
                "openid",
                "https://www.googleapis.com/auth/userinfo.email",
                "https://www.googleapis.com/auth/userinfo.profile",
            ],
            require_authorization_consent=False,
        )
    except Exception as e:
        logger.error("Failed to create MCP GoogleProvider: %s", e)
        return None


MCP_AUTH_FACTORY = _mcp_google_auth_factory
```

Add the redirect URI to [Google Cloud Console](https://console.cloud.google.com)
→ APIs & Services → Credentials → your OAuth client:

```
https://mcp.yourcompany.com/auth/callback
```

---

## Step 4 — Deploy the MCP Service

The MCP service uses the **master image** with a different start command.
It shares the same `superset_config.py` and database as your web server.

### Docker (local / single server)

```bash
docker run -d \
  --name superset-mcp \
  -p 5008:5008 \
  -e GOOGLE_CLIENT_ID="your-client-id" \
  -e GOOGLE_CLIENT_SECRET="your-client-secret" \
  -e MCP_BASE_URL="https://mcp.yourcompany.com" \
  -e DATABASE_URL="postgresql://user:pass@db-host/superset" \
  -v /path/to/superset_config.py:/app/pythonpath/superset_config.py:ro \
  your-registry/superset:mcp-master \
  superset mcp run --host 0.0.0.0 --port 5008
```

### Kubernetes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: superset-mcp
  namespace: superset
spec:
  replicas: 1
  selector:
    matchLabels:
      app: superset-mcp
  template:
    metadata:
      labels:
        app: superset-mcp
    spec:
      containers:
      - name: mcp
        image: your-registry/superset:mcp-master
        command: ["superset", "mcp", "run", "--host", "0.0.0.0", "--port", "5008"]
        ports:
        - containerPort: 5008
        env:
        - name: GOOGLE_CLIENT_ID
          valueFrom:
            secretKeyRef:
              name: superset-google-oauth
              key: GOOGLE_CLIENT_ID
        - name: GOOGLE_CLIENT_SECRET
          valueFrom:
            secretKeyRef:
              name: superset-google-oauth
              key: GOOGLE_CLIENT_SECRET
        - name: MCP_BASE_URL
          value: "https://mcp.yourcompany.com"
        - name: SUPERSET_CONFIG_PATH
          value: /app/pythonpath/superset_config.py
        volumeMounts:
        - name: superset-config
          mountPath: /app/pythonpath
          readOnly: true
        livenessProbe:
          httpGet:
            path: /.well-known/oauth-authorization-server
            port: 5008
          initialDelaySeconds: 30
          periodSeconds: 15
      volumes:
      - name: superset-config
        configMap:
          name: superset-config  # same ConfigMap as your web server
---
apiVersion: v1
kind: Service
metadata:
  name: superset-mcp
  namespace: superset
spec:
  selector:
    app: superset-mcp
  ports:
  - port: 5008
    targetPort: 5008
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superset-mcp
  namespace: superset
spec:
  rules:
  - host: mcp.yourcompany.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: superset-mcp
            port:
              number: 5008
  tls:
  - hosts:
    - mcp.yourcompany.com
    secretName: superset-mcp-tls
```

```bash
# Create secret
kubectl create secret generic superset-google-oauth \
  --from-literal=GOOGLE_CLIENT_ID="your-client-id" \
  --from-literal=GOOGLE_CLIENT_SECRET="your-client-secret" \
  -n superset

# Deploy
kubectl apply -f mcp-deployment.yaml
kubectl rollout status deployment/superset-mcp -n superset
```

---

## Step 5 — Verify

```bash
# Should return JSON with authorization_endpoint, token_endpoint, etc.
curl https://mcp.yourcompany.com/.well-known/oauth-authorization-server

# Should return 401 (auth required — means the MCP service is running)
curl https://mcp.yourcompany.com/mcp
```

Connect an MCP client (e.g., Claude Desktop), authenticate with Google,
and call `get_instance_info` to confirm the user resolves correctly.

---

## User Note

Each user must have **logged into Superset at least once** before using MCP.
Their Google email must exist in Superset's user database. MCP looks up users
by email from the Google OAuth token — if the user record doesn't exist, auth fails.

---

## Building the Image

MCP is not in any released Superset version. Build from master:

```bash
git clone https://github.com/apache/superset.git
cd superset
git checkout master  # or pin to a specific commit SHA

docker build \
  --target lean \
  -t your-registry/superset:mcp-master-$(date +%Y%m%d) \
  -f Dockerfile .

docker push your-registry/superset:mcp-master-$(date +%Y%m%d)
```

Pin to a specific commit SHA for reproducible builds — do not use `latest`.

---

## Rollback

If anything goes wrong:

1. Stop the MCP service (does not affect the web server)
2. Restore the database backup: `psql superset < superset_backup_YYYYMMDD.sql`
3. The 2.1.0 web server was never changed — it continues working on the original schema

The 2.1.0 web server itself is never touched during this process.

---

## Next Step: Full Upgrade

This hybrid setup is a bridge, not a permanent solution. The recommended
upgrade path is `2.1.0 → 4.1.4 → 5.0.0 → 6.0.0 → master`, tested in staging
at each step. See `research/mcp-production-guide.md` for the full upgrade guide.
