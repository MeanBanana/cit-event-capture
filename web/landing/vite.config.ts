import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import {cpSync, existsSync, readFileSync, statSync} from 'node:fs';
import {extname, join, normalize, resolve} from 'node:path';
import {defineConfig, type Plugin} from 'vite';

/**
 * The root admin's console (web/admin-console) is plain HTML + JS and stays
 * where it is. This plugin puts it under /admin/ on the landing site:
 *   npm run dev    serves it live from ../admin-console at /admin/
 *   npm run build  copies it into dist/admin/, so dist/ is the whole website
 * The "Admin login" button in the header links to /admin/.
 */
const ADMIN_DIR = resolve(__dirname, '../admin-console');

const TYPES: Record<string, string> = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.txt': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8',
};

function adminConsole(): Plugin {
  return {
    name: 'argus-admin-console',
    configureServer(server) {
      server.middlewares.use((req, res, next) => {
        const url = (req.url ?? '').split('?')[0];
        if (url === '/admin') {
          res.statusCode = 301;
          res.setHeader('Location', '/admin/');
          res.end();
          return;
        }
        if (!url.startsWith('/admin/')) return next();
        const rel = normalize(decodeURIComponent(url.slice('/admin/'.length)) || 'index.html');
        const file = join(ADMIN_DIR, rel);
        if (!file.startsWith(ADMIN_DIR) || !existsSync(file) || statSync(file).isDirectory()) return next();
        res.setHeader('Content-Type', TYPES[extname(file)] ?? 'application/octet-stream');
        res.end(readFileSync(file));
      });
    },
    closeBundle() {
      if (existsSync(ADMIN_DIR)) {
        cpSync(ADMIN_DIR, resolve(__dirname, 'dist/admin'), {recursive: true});
      }
    },
  };
}

export default defineConfig({
  plugins: [react(), tailwindcss(), adminConsole()],
  build: {
    // hero layers and reel stills live in public/ and get served as they are
    target: 'es2020',
  },
});
