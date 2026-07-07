Node.js Universal V5 Production Egg

A hardened, production-ready universal Node.js egg for Pterodactyl.

Designed for:

- Discord bots
- Express.js APIs
- Next.js applications
- NestJS backends
- TypeScript applications
- General Node.js services

Node.js Universal V5 is the final production release focused on security, stability, and easy deployment.

---

Features

Runtime Support

Supported Node.js versions:

- Node.js 18
- Node.js 20
- Node.js 22
- Node.js 24
- Node.js 25

Supported package managers:

- npm
- yarn
- pnpm
- bun

---

Security Features

Safe Environment Loader

The egg includes a secure ".env" parser.

It:

- Does not use "source"
- Does not execute commands
- Prevents environment injection
- Supports normal KEY=VALUE formats
- Protects sensitive variables

---

Secure Git Authentication

Private repositories are supported using temporary authentication.

Security rules:

- Tokens are never stored in Git URLs
- Tokens are never written to ".git/config"
- Credentials are removed after installation
- Logs never display authentication data

Supported providers:

- GitHub
- GitLab
- Bitbucket
- Gitea

---

Crash Protection

The egg includes production crash handling.

Features:

- Automatic restart after crashes
- Crash frequency detection
- Restart limits
- Graceful shutdown handling
- Discord crash alerts

Protection against:

- Infinite restart loops
- Broken deployments
- Unexpected application failures

---

Monitoring System

Optional background monitoring:

Tracks:

- CPU usage
- RAM usage
- Disk usage
- Application status
- Restart count
- Uptime

Can send alerts through Discord webhooks.

---

Backup System

Built-in automated backups.

Features:

- Scheduled backups
- Backup rotation
- Restore support
- Emergency backup before restore

Security protections:

- Prevents archive traversal
- Excludes unnecessary folders
- Protects application files

Excluded:

node_modules
.git
temporary files

---

Database Support

Compatible with:

- MySQL
- MariaDB
- PostgreSQL
- MongoDB
- Redis

Includes optional:

- Connection checks
- Prisma generation
- Database migration support

---

Proxy Support

Designed to work behind:

- Cloudflare
- Nginx
- HAProxy
- Reverse proxies

Supports:

- Trust proxy configuration
- Rate-limit hints
- Real client IP handling

Note:

This egg does not replace external DDoS protection.

---

Installation

1. Download the egg JSON file:

egg-nodejs-universal-v5.json

2. Import it into:

Pterodactyl Panel
→ Admin
→ Nests
→ Import Egg

3. Select a Docker image:

Example:

ghcr.io/ptero-eggs/yolks:nodejs_22

4. Configure variables.

5. Start your server.

---

Recommended Production Settings

Example:

NODE_ENV=production

PACKAGE_MANAGER=auto

ENABLE_MONITORING=1

ENABLE_BACKUPS=1

ENABLE_DISCORD_STATUS=1

---

Environment Variables

Common variables:

Variable| Purpose
MAIN_FILE| Application entry file
PORT| Application port
HOST| Bind address
NODE_ENV| Environment mode
PACKAGE_MANAGER| npm/yarn/pnpm/bun
GIT_ADDRESS| Repository URL
BRANCH| Git branch

---

Supported Applications

Examples:

Discord Bot:

index.js

Express API:

server.js

TypeScript:

src/index.ts

Next.js:

npm run start

NestJS:

npm run start:prod

---

Admin Features

Administrator-only options:

- Custom install commands
- Custom startup commands

These are disabled for normal users because they allow command execution.

---

Security Philosophy

Node.js Universal V5 follows these principles:

- Secure defaults
- Minimal privilege
- No hidden credential storage
- No unsafe command execution
- Production reliability
- Transparent configuration

---

License

Choose a license before public release.

Recommended:

MIT License
or
Apache 2.0 License

---

Credits

Created for the Pterodactyl community.

Built for developers running production Node.js services.
