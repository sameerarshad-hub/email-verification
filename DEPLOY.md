# Deploying MailForge to a DigitalOcean Ubuntu Droplet

This guide covers two ways to run MailForge on a fresh **Ubuntu 22.04 / 24.04**
droplet. **Option A (Docker)** is recommended — it's the most reproducible and
isolates all dependencies. **Option B (Node + systemd)** is for when you don't
want Docker.

Either way, the app runs on port `3000` and you put **Caddy** (auto-HTTPS) or
**nginx** in front of it for production.

---

## 0. What you need

- A **DigitalOcean droplet** running **Ubuntu 22.04 or 24.04** (1 vCPU / 1 GB
  RAM is enough to start; bump to 2 GB for large 30k-row CSV jobs).
- The droplet's **public IP**.
- (Optional but recommended) a **domain name** pointed at the droplet's IP via
  an **A record** — required for free automatic HTTPS.
- Your **GitHub repo** with this code pushed to it.

### Push to GitHub first

```bash
# From your local machine (once the project is committed)
git remote add origin git@github.com:<you>/mailforge.git
git push -u origin main
```

> **Note:** the test SQLite database (`db/custom.db`) and `.env` are gitignored,
> so they are **not** pushed. The droplet creates a fresh empty database on
> first boot via `prisma db push`.

---

## Option A — Docker (recommended)

### 1. SSH into the droplet and install Docker

```bash
ssh root@<droplet-ip>

# Install Docker Engine + Compose plugin
apt-get update
apt-get install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
docker --version   # sanity check
```

### 2. Clone the repo

```bash
cd /opt
git clone https://github.com/<you>/mailforge.git
cd mailforge
```

### 3. Build and start

```bash
docker compose up -d --build
```

That's it. The first build takes ~3–5 minutes. On every subsequent start the
container automatically runs `prisma db push` (creates/migrates the SQLite
tables) and then starts the Node server on port 3000.

Check it:

```bash
docker compose ps
docker compose logs -f mailforge
curl http://localhost:3000/      # should return the HTML page
```

Open `http://<droplet-ip>:3000` in your browser. (Remember to add a firewall
rule allowing port 3000, or skip straight to step 4 and only expose 80/443.)

### 4. (Recommended) Put Caddy in front for HTTPS

The app container only listens on `3000`. For production you want **80/443 with
automatic HTTPS**. Run Caddy directly on the droplet (not in Docker) — it's the
simplest path:

```bash
apt-get install -y caddy
```

Edit `/etc/caddy/Caddyfile` to use your domain (a template is at
`deploy/Caddyfile.prod` in this repo):

```caddyfile
mailforge.example.com {
    encode gzip zstd
    reverse_proxy localhost:3000 {
        header_up Host {host}
        header_up X-Real-IP {remote_host}
        header_up X-Forwarded-For {remote_host}
        header_up X-Forwarded-Proto {scheme}
        flush_interval -1
    }
}
```

```bash
systemctl reload caddy
```

Caddy automatically provisions a Let's Encrypt certificate. Visit
`https://mailforge.example.com`. Done.

> **Firewall:** with Caddy in place you can close port 3000 and only leave
> 22/80/443 open:
> ```bash
> ufw allow 22/tcp && ufw allow 80/tcp && ufw allow 443/tcp && ufw enable
> ```

### 5. Updating

```bash
cd /opt/mailforge
git pull
docker compose up -d --build
```

The `mailforge-data` volume keeps your SQLite DB across rebuilds.

### 6. Backing up the database

```bash
docker compose cp mailforge:/app/data/custom.db ./backup-$(date +%F).db
```

---

## Option B — Node + systemd (no Docker)

### 1. SSH into the droplet and install Node + Bun + Caddy

```bash
ssh root@<droplet-ip>

# Node 20
curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
apt-get install -y nodejs git build-essential

# Bun (used for install + build)
curl -fsSL https://bun.sh/install | bash
echo 'export BUN_INSTALL="$HOME/.bun"' >> ~/.bashrc
echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc

# Caddy (reverse proxy + HTTPS)
apt-get install -y caddy
```

### 2. Create a dedicated user and clone

```bash
useradd -r -m -d /opt/mailforge -s /bin/bash mailforge
cd /opt
git clone https://github.com/<you>/mailforge.git
chown -R mailforge:mailforge /opt/mailforge
```

### 3. Create the data dir + `.env`

```bash
mkdir -p /var/lib/mailforge
chown mailforge:mailforge /var/lib/mailforge

sudo -u mailforge bash -c 'cat > /opt/mailforge/.env <<EOF
DATABASE_URL=file:/var/lib/mailforge/custom.db
PORT=3000
HOSTNAME=0.0.0.0
NODE_ENV=production
EOF'
```

### 4. Install deps and build

```bash
sudo -u mailforge bash -c '
  cd /opt/mailforge
  bun install --frozen-lockfile
  bun run db:push      # creates the SQLite tables
  bun run build        # produces .next/standalone
'
```

### 5. Install the systemd service

```bash
cp /opt/mailforge/deploy/mailforge.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mailforge
systemctl status mailforge
journalctl -u mailforge -f   # live logs
```

### 6. Configure Caddy for HTTPS

Same as step A.4 — edit `/etc/caddy/Caddyfile` with your domain
(template at `deploy/Caddyfile.prod`), then `systemctl reload caddy`.

### 7. Updating

```bash
cd /opt/mailforge
sudo -u mailforge git pull
sudo -u mailforge bash -c 'cd /opt/mailforge && bun install --frozen-lockfile && bun run build'
systemctl restart mailforge
```

---

## Notes & gotchas

### Streaming / long requests
The email-verification endpoint streams NDJSON and a long verification job can
keep a connection open for many minutes. Caddy handles this automatically with
`flush_interval -1` (already in the template). If you use **nginx** instead, add:

```nginx
location / {
    proxy_pass http://localhost:3000;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_read_timeout 3600s;
    proxy_send_timeout 3600s;
}
```

### Memory for big CSVs
Parsing a 30k-row / 50 MB CSV and running parallel verifications is RAM-heavy.
If the process gets OOM-killed on a 1 GB droplet, either:
- upgrade to a 2 GB droplet, or
- lower `MAX_ROWS` in `src/app/api/parse-csv/route.ts` and rebuild.

### SQLite is single-file
The database lives at `/app/data/custom.db` (Docker) or
`/var/lib/mailforge/custom.db` (Node). It's perfect for a single-droplet
deployment. If you later need multi-droplet scaling, switch `prisma/schema.prisma`
to PostgreSQL and update `DATABASE_URL`.

### `typescript.ignoreBuildErrors`
`next.config.ts` has `ignoreBuildErrors: true` so the build won't fail on type
warnings. This is intentional for now — the app builds and runs cleanly. You can
flip it to `false` later if you want strict type checking during build.

### Environment variables
Only `DATABASE_URL` is required. The app has no other secrets (API keys for the
MailTester.ninja verification service are entered in the UI and stored in the
browser's `localStorage`, never on the server).

---

## Quick troubleshooting

| Symptom | Fix |
|---|---|
| `curl localhost:3000` → connection refused | `docker compose logs mailforge` / `journalctl -u mailforge` — check it actually started |
| 502 from Caddy | app not running on 3000, or crashed — check logs |
| `prisma: command not found` (non-Docker) | run `bun install` again; `postinstall` generates the client |
| HTTPS not working | DNS A record not propagated yet — check `dig mailforge.example.com` |
| DB locked / `SQLITE_BUSY` | only one process should touch the `.db` file; make sure no stale `mailforge` process is running |
