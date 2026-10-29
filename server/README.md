# OpenNexus Server

A small server that stores OpenNexus share links. Use it when you'd rather host links
yourself than keep them in an S3 bucket or a GitHub gist.

The app seals a map on your Mac before it uploads anything. The key is in the link, after
the `#`, and browsers never send that part. So the server stores bytes it can't read, and
never sees a key, a password or a map.

## What it does

| Request | Who may make it | What it does |
| --- | --- | --- |
| `GET /v1/health` | anyone | Says what it is: `{"service":"opennexus-server","version":1}` |
| `POST /v1/shares` | the upload token | Stores a sealed share; answers `{"id", "secret"}` |
| `GET /v1/shares/{id}` | anyone, from any origin, without cookies | Returns the sealed bytes |
| `PUT /v1/shares/{id}` | that share's write secret | Replaces it (the link stays the same) |
| `DELETE /v1/shares/{id}` | that share's write secret | Deletes it (the link shows "turned off") |

- **Only sealed shares.** A body that isn't an OpenNexus envelope is refused.
- **Write secrets.** Each share gets its own. The app keeps it in your Keychain; the
  server keeps only its SHA-256.
- **Expiry.** `X-OpenNexus-Expires` (ISO 8601) on `POST` or `PUT` sets when a share stops
  being served. Expired shares answer 410 and are deleted.
- **Limits.** A size limit, and a per-address rate limit for writes and for reads.
- **Storage.** Files on disk (a Docker volume), or a private S3-compatible bucket.
- **Nothing readable in its logs.** It logs that a share was stored and its size, never its bytes.

## Settings

All settings are environment variables.

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPENNEXUS_UPLOAD_TOKEN` | (required) | The token the app's destination uses: 16 characters or more. Make one with `openssl rand -base64 32`. |
| `OPENNEXUS_PORT` | `8787` | Port to listen on |
| `OPENNEXUS_HOST` | `0.0.0.0` | Address to listen on |
| `OPENNEXUS_STORAGE` | `disk` | `disk` or `s3` |
| `OPENNEXUS_DATA_DIR` | `/data` | Where `disk` storage keeps shares |
| `OPENNEXUS_MAX_BYTES` | `52428800` | Largest share, in bytes (50 MB) |
| `OPENNEXUS_MAX_DAYS` | `0` | When not 0, the longest a share may live; shares without an expiry get this one |
| `OPENNEXUS_WRITES_PER_MINUTE` | `30` | Creates, updates and deletes per minute from one address |
| `OPENNEXUS_READS_PER_MINUTE` | `600` | Reads per minute from one address |
| `OPENNEXUS_TRUST_PROXY` | off | Set to `1` behind a reverse proxy, so limits use `X-Forwarded-For` |

For `s3` storage, also set:

| Variable | Default |
| --- | --- |
| `OPENNEXUS_S3_ENDPOINT` | (required), for example `https://s3.us-east-1.amazonaws.com` |
| `OPENNEXUS_S3_BUCKET` | (required) |
| `OPENNEXUS_S3_ACCESS_KEY`, `OPENNEXUS_S3_SECRET_KEY` | (required) |
| `OPENNEXUS_S3_REGION` | `us-east-1` |
| `OPENNEXUS_S3_PREFIX` | `shares/` |
| `OPENNEXUS_S3_PATH_STYLE` | on (set to `0` for virtual-hosted addresses) |

The bucket can stay private. Readers fetch shares through the server.

## Run it with Docker and Caddy

`compose.yaml` runs the server behind [Caddy](https://caddyserver.com), which gets and
renews the HTTPS certificate.

1. Point a DNS name at the machine, for example `share.example.com`.
2. Copy `.env.example` to `.env`, then set `OPENNEXUS_DOMAIN` and `OPENNEXUS_UPLOAD_TOKEN`.
3. Start it:

   ```sh
   docker compose up -d
   ```

4. In OpenNexus, open Settings › Sharing › Add Destination › OpenNexus Server. Enter
   `https://share.example.com` and the upload token, then choose Test.

To try it on one computer, set `OPENNEXUS_DOMAIN=localhost` (Caddy uses its own local
certificate) and, if ports 80 and 443 are taken, `HTTP_PORT=8080` and `HTTPS_PORT=8443`.

### A home server (ZimaOS)

ZimaOS runs Docker, but its `docker` command needs `sudo`.

1. Copy this folder to the server, for example with the Files app or `scp`.
2. In a terminal on the server, run `sudo docker compose up -d` in the folder.
3. To reach it from outside your network, forward ports 80 and 443 on your router to the
   server, and point a DNS name at your public address. Or keep it local, and set
   `OPENNEXUS_DOMAIN` to the server's local name, such as `zima.local`; links then open
   only on your network. Caddy signs a local name's certificate itself, so every device
   that makes or opens links must trust Caddy's root certificate: copy it out with
   `sudo docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt .`, then
   add it in Keychain Access (or the device's settings) and trust it.

OpenNexus talks plain `http://` only to the Mac it runs on (`localhost`, `127.0.0.1`), for
testing. A server anywhere else needs HTTPS: a token would otherwise cross the network in
the clear, and the viewer, an HTTPS page, can't read from an HTTP address.

### A VPS

Any Linux server with Docker works: install Docker, open ports 80 and 443 in the firewall,
copy this folder and run `docker compose up -d`. Back up the `shares` volume like any other
data, or use `s3` storage and the bucket's own versioning.

### Fly.io

Fly.io gives HTTPS itself, so the server runs alone. Save this as `fly.toml` next to the
Dockerfile, choosing your own app name:

```toml
app = "my-opennexus-share"

[build]
  dockerfile = "Dockerfile"

[env]
  OPENNEXUS_TRUST_PROXY = "1"

[[mounts]]
  source = "shares"
  destination = "/data"

[http_service]
  internal_port = 8787
  force_https = true
  auto_stop_machines = "stop"
  auto_start_machines = true
```

Then:

```sh
fly launch --no-deploy --copy-config
fly volumes create shares --size 1
fly secrets set OPENNEXUS_UPLOAD_TOKEN="$(openssl rand -base64 32)"
fly deploy
```

Use `https://my-opennexus-share.fly.dev` as the server's address in OpenNexus.

## Develop

```sh
swift build
swift test
OPENNEXUS_UPLOAD_TOKEN=dev-token-0123456789 OPENNEXUS_DATA_DIR=/tmp/shares swift run
```

`scripts/test-share.sh` in the repository starts MinIO and two servers in Docker
(`compose.test.yaml`), makes real links against them, and opens them in browsers.

MinIO no longer publishes images, so `test/minio` builds its last community release from
source. It's a test fixture only.
