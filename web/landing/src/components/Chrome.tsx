import {useState, type MouseEvent} from 'react';
import {brand, nav, sources} from '../content';
import {scrollToHash} from '../lib/scroll';

function go(e: MouseEvent<HTMLAnchorElement>, then?: () => void) {
  const hash = e.currentTarget.getAttribute('href');
  if (!hash?.startsWith('#')) return;
  e.preventDefault();
  then?.();
  scrollToHash(hash);
}

/** The Argus shield logo mark. */
export function Mark({className = ''}: {className?: string}) {
  return <img src="/logo.svg" alt="" aria-hidden="true" className={className} />;
}

/** Lock icon on the admin login button. */
function Lock({className = ''}: {className?: string}) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className={className} fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round">
      <rect x="5" y="11" width="14" height="9" rx="2" />
      <path d="M8 11V8a4 4 0 0 1 8 0v3" />
    </svg>
  );
}

export function Header() {
  const [open, setOpen] = useState(false);
  return (
    <header className="fixed inset-x-0 top-0 z-50 text-white">
      <div className="flex items-center justify-between gap-4 px-4 pt-4 sm:px-6 sm:pt-5 md:px-[3vw]">
        <a href="#top" onClick={(e) => go(e)} className="flex items-center gap-2.5" aria-label={`${brand.name} — back to top`}>
          <Mark className="h-7 w-auto" />
          <span className="font-display text-[0.8125rem] tracking-[0.3em] max-sm:hidden">{brand.wordmark}</span>
        </a>
        <div className="flex items-center gap-3 md:gap-8">
          <nav aria-label="Primary" className="hidden items-center gap-8 md:flex">
            {nav.map((item) => (
              <a key={item.href} href={item.href} onClick={(e) => go(e)} className="font-mono text-label text-white/75 uppercase transition-colors hover:text-white">
                {item.label}
              </a>
            ))}
          </nav>
          <button type="button" onClick={() => setOpen((v) => !v)} aria-expanded={open} aria-controls="menu" className="font-mono text-label uppercase md:hidden">
            {open ? 'Close' : 'Menu'}
          </button>
          {/* Top right corner: link to the root admin's console. */}
          <a
            href={brand.adminHref}
            className="flex items-center gap-2 rounded-[4px] bg-signal px-3.5 py-2.5 font-mono text-label text-void uppercase transition-colors hover:bg-white md:px-4"
          >
            <Lock className="size-3.5" />
            Admin login
          </a>
        </div>
      </div>
      <div id="menu" inert={!open} className={`fixed inset-0 -z-10 flex flex-col justify-center gap-6 bg-void/95 px-6 backdrop-blur-xl transition-opacity md:hidden ${open ? 'opacity-100' : 'pointer-events-none opacity-0'}`}>
        {nav.map((item, i) => (
          <a key={item.href} href={item.href} onClick={(e) => go(e, () => setOpen(false))} className="flex items-baseline gap-4 font-display text-[1.5rem] tracking-[0.12em] uppercase">
            <span className="font-mono text-label text-signal">0{i + 1}</span>
            {item.label}
          </a>
        ))}
      </div>
    </header>
  );
}

export function Footer() {
  return (
    <footer className="border-t border-white/10 bg-void px-4 py-8 sm:px-6 md:px-[6vw]">
      <div className="flex flex-col gap-4 font-mono text-label text-steel/50 uppercase md:flex-row md:items-center md:justify-between">
        <span className="flex items-center gap-2.5 text-white/80">
          <Mark className="h-5 w-auto" />
          {brand.wordmark} · Eduvos research project
        </span>
        <span>© {new Date().getFullYear()} · Attack scenes illustrated for this site</span>
        <a href="#top" onClick={(e) => go(e)} className="hover:text-white">
          Back to the top ↑
        </a>
      </div>
      <p className="mt-6 text-[0.75rem] leading-relaxed text-steel/40">
        Statistics:{' '}
        {sources.map((s) => (
          <a key={s.href} href={s.href} target="_blank" rel="noreferrer" className="underline decoration-white/20 underline-offset-2 hover:text-white">
            {s.label}
          </a>
        ))}
        . Quarterly figure from SAPS statistics, yearly figure from the Cash-in-Transit Association of South Africa (CITASA), as reported there.
      </p>
    </footer>
  );
}
