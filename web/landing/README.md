# Argus Shield — landing page

The public website for Argus Shield: a scroll-driven product page (Vite +
React + TypeScript + Tailwind v4 + Lenis), with the root admin's console
from `../admin-console` served at **/admin/** — that's where the
**Admin login** button (top right) goes.

## Run it

```bash
cd web/landing
npm install        # first time only
npm run dev        # http://localhost:3006   (admin console: http://localhost:3006/admin/)
```

## Build for hosting

```bash
npm run build      # -> web/landing/dist/  (the whole website, admin console included in dist/admin/)
```

Upload/deploy the `dist/` folder to any static host (Netlify, Vercel,
Cloudflare Pages, GitHub Pages…). Nothing else is needed — the admin console
talks to Supabase directly from the browser with the publishable key in
`admin-console/config.js`, exactly as before.

## Where things are

| What | Where |
| --- | --- |
| All the words on the page | `src/content.ts` |
| Hero (the ambush seen through a witness's windscreen, AI boxes, shots) | `src/components/Hero.tsx` |
| The attack, frame by frame (reel of stills) | `src/components/AttackLog.tsx` |
| Phone → cloud → AI → case file, drawn on scroll | `src/components/Pipeline.tsx` |
| Citizen / Investigator / Admin cards | `src/components/Roles.tsx` |
| Contact form + statistics | `src/components/Contact.tsx` |
| Header (Admin login button) + footer | `src/components/Chrome.tsx` |
| Hero layer images (desktop `d/`, phone `m/`) | `public/layers/` |
| Reel stills, share image | `public/media/` |
| Where each person/vehicle/weapon sits in the hero layers | `src/scene.ts` |

## Before going live

- Set the team's real email in `src/content.ts` (`brand.email`) — the
  contact form drafts an email to it.
- The attack scenes are illustrations made for this site. To use your own
  photos in the reel, replace `public/media/cards/s1.webp … s4.webp`
  (portrait, 840 × 1120) — only use photos you have the rights to.
- Statistics are sourced in the footer (CITASA / SAPS, via Daily News).
