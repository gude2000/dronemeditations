# Deployment — dronemeditations.com on Vercel + Namecheap

The web app at `web/` is the deployable target. Native iOS lives alongside
but doesn't deploy here.

## One-time setup

### 1. Connect the GitHub repo to Vercel

1. Sign in to [vercel.com](https://vercel.com) with your **GitHub** account
   (`gude2000`). Free Hobby tier is enough.
2. Click **Add New… → Project**.
3. Select **`gude2000/dronemeditations`** from the import list.
4. On the *Configure* screen, set:
   - **Root Directory**: `web`  ← important; `vercel.json` lives there
   - **Framework Preset**: *Other* (auto-detect should pick "Other")
   - **Build Command**: leave empty
   - **Output Directory**: `.` (single dot — same folder as index.html)
5. Click **Deploy**. First deploy takes ~30s.

You should land on `https://dronemeditations.vercel.app` (or a similar
auto-generated subdomain) with the app running.

### 2. Add the custom domain

In the Vercel project dashboard:
1. **Settings → Domains**.
2. Type `dronemeditations.com` and click **Add**.
3. Vercel will show DNS instructions. Use these:

#### Apex domain (`dronemeditations.com`)
| Type | Host | Value | TTL |
|---|---|---|---|
| **A** | `@` | `76.76.21.21` | Automatic |

#### `www` subdomain
| Type | Host | Value | TTL |
|---|---|---|---|
| **CNAME** | `www` | `cname.vercel-dns.com.` | Automatic |

### 3. Update DNS in Namecheap

1. Log into [Namecheap](https://www.namecheap.com).
2. **Domain List → Manage** next to `dronemeditations.com`.
3. **Advanced DNS** tab.
4. Delete any default parking / URL-redirect records that already exist
   on `@` or `www`.
5. **Add New Record** twice — one **A Record** for `@` pointing to
   `76.76.21.21`, one **CNAME Record** for `www` pointing to
   `cname.vercel-dns.com.` (keep the trailing dot when entering).
6. Click the green **✓** to save each row.

Propagation typically takes 5–15 minutes; can take up to a few hours.
Vercel automatically provisions a Let's Encrypt SSL certificate once
the DNS resolves.

You should be able to hit **https://dronemeditations.com** as soon as
DNS propagates and the cert finishes issuing.

## Subsequent deploys

Vercel watches the `main` branch. Every `git push origin main` triggers
a new build + deploy automatically. Preview deploys are created for any
non-main branches too (handy for staging new features).

## Local development

```bash
cd web
npm start          # → http://localhost:5173
```

Nothing about the local workflow changes when Vercel is hooked up.
