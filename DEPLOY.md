# Deployment — dronemeditations.com on GitHub Pages + Namecheap

The web app at `web/` is the deployable target. Native iOS lives alongside
but doesn't deploy here.

## How it works

The repo includes a GitHub Actions workflow at
[`.github/workflows/deploy-pages.yml`](.github/workflows/deploy-pages.yml)
that runs on every push to `main` (when files in `web/` change). It
uploads the entire `web/` directory as a Pages artifact and publishes it,
so the live site always matches what's in the `web/` folder on `main`.

The custom domain `dronemeditations.com` is wired through the
[`web/CNAME`](web/CNAME) file, which Pages reads to know which domain
to associate with the deployment.

## One-time setup

### 1. Enable Pages on the repo

1. Go to **https://github.com/gude2000/dronemeditations/settings/pages**.
2. Under **Build and deployment → Source**, choose **GitHub Actions**.
   (Don't pick "Deploy from branch" — we use the workflow.)
3. Don't add a custom domain through this UI yet; the `CNAME` file
   already declares it. Once DNS resolves Pages will pick it up.

### 2. Trigger the first deploy

Either:
- Push any change under `web/` (or this `DEPLOY.md`); the workflow runs
  automatically, or
- Open **Actions** tab → **Deploy web to GitHub Pages** →
  **Run workflow** button (manual dispatch).

When the workflow completes (~30s) Pages will be live at:
`https://gude2000.github.io/dronemeditations/` — and once DNS is in
place, `https://dronemeditations.com`.

### 3. Namecheap DNS

In Namecheap **Domain List → Manage → Advanced DNS**, delete any
default parking / URL-redirect records on `@` or `www`, then add:

#### Apex `dronemeditations.com` — 4 A records
| Type | Host | Value | TTL |
|---|---|---|---|
| **A** | `@` | `185.199.108.153` | Automatic |
| **A** | `@` | `185.199.109.153` | Automatic |
| **A** | `@` | `185.199.110.153` | Automatic |
| **A** | `@` | `185.199.111.153` | Automatic |

#### `www` subdomain — CNAME
| Type | Host | Value | TTL |
|---|---|---|---|
| **CNAME** | `www` | `gude2000.github.io.` | Automatic |

(Keep the trailing dot on the CNAME value when Namecheap accepts it.)

Click the green ✓ to save each row.

### 4. Wait & verify

- DNS propagation: usually 5–30 min, can take a few hours.
- GitHub Pages issues a Let's Encrypt cert automatically once DNS
  resolves; this can take an extra ~15 min after DNS propagates.
- Check status at **Settings → Pages**. When it says "Your site is
  live at https://dronemeditations.com" with a green check on
  HTTPS, you're done.

## Subsequent deploys

`git push origin main` triggers the workflow automatically when `web/`
files change. The Actions tab shows build status; the Environments
panel shows the most-recent successful deploy URL.

## Local development

```bash
cd web
npm start          # → http://localhost:5173
```

(`npm start` runs `npx serve .` — no build step required.)
