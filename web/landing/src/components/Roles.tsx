import type {MouseEvent} from 'react';
import {contact, roles} from '../content';
import {useReveals} from '../hooks/useReveals';
import {scrollToHash} from '../lib/scroll';

/** In-page links preselect the role in the contact form. /admin/ is an actual page. */
const follow = (e: MouseEvent<HTMLAnchorElement>, href: string, role: string) => {
  if (!href.startsWith('#')) return;
  e.preventDefault();
  const select = document.querySelector<HTMLSelectElement>('#contact select[name="role"]');
  if (select && contact.roles.includes(role)) select.value = role;
  scrollToHash(href);
};

/** The three kinds of people Argus is for. Each card gets one scan ring per feature group. */
export function Roles() {
  const ref = useReveals<HTMLElement>();
  return (
    <section ref={ref} id="roles" aria-labelledby="roles-title" className="relative bg-void px-4 py-28 sm:px-6 md:px-[6vw] md:py-40">
      <div className="flex flex-col gap-3 md:flex-row md:items-end md:justify-between" data-reveal>
        <div>
          <p className="font-mono text-label text-signal uppercase">{roles.eyebrow}</p>
          <h2 id="roles-title" className="mt-4 font-display text-display text-white">
            {roles.heading}
          </h2>
        </div>
        <p className="max-w-[24rem] font-mono text-label text-steel/50 uppercase md:text-right">{roles.note}</p>
      </div>

      <ol className="mt-14 grid gap-4 md:mt-20 md:grid-cols-3 md:gap-5">
        {roles.items.map((r, i) => (
          <li
            key={r.name}
            data-reveal
            style={{transitionDelay: `${i * 110}ms`}}
            className={`group relative flex flex-col overflow-hidden rounded-[8px] p-6 ring-1 transition-[transform,box-shadow] duration-500 hover:-translate-y-1.5 md:p-8 ${
              r.featured ? 'bg-void-2 ring-signal/60 hover:shadow-[0_30px_80px_-30px_rgb(255_171_64/0.45)]' : 'bg-void-2/60 ring-white/10 hover:ring-white/25'
            }`}
          >
            {/* Scan rings, like the AI sweeping a frame. */}
            <svg aria-hidden="true" viewBox="0 0 200 200" className="absolute -top-10 -right-10 size-48 text-white/10 transition-transform duration-[1.2s] group-hover:rotate-45">
              {Array.from({length: r.rings}, (_, k) => (
                <ellipse key={k} cx="100" cy="100" rx={40 + k * 18} ry={18 + k * 8} fill="none" stroke="currentColor" transform={`rotate(${-20 + k * 14} 100 100)`} />
              ))}
              <circle cx="100" cy="100" r="9" fill="currentColor" />
            </svg>

            {r.featured && <span className="self-start rounded-[3px] bg-signal px-2 py-1 font-mono text-[0.625rem] tracking-[0.14em] text-void uppercase">Where cases are solved</span>}
            <h3 className={`font-display text-[1.25rem] tracking-[0.14em] text-white uppercase ${r.featured ? 'mt-5' : ''}`}>{r.name}</h3>
            <p className="mt-6 flex items-baseline gap-2">
              <span className="font-display text-[3.5rem] leading-none text-white">{r.stat}</span>
              <span className="font-mono text-label text-steel/60 uppercase">{r.unit}</span>
            </p>
            <ul className="mt-8 space-y-2.5 border-t border-white/10 pt-6">
              {r.lines.map((l) => (
                <li key={l} className="flex gap-3 text-[0.9375rem] text-steel/80">
                  <span aria-hidden="true" className="mt-2 size-1 shrink-0 rounded-full bg-signal" />
                  {l}
                </li>
              ))}
            </ul>
            <span className="mt-auto" aria-hidden="true" />
            <a
              href={r.href}
              onClick={(e) => follow(e, r.href, r.name)}
              className={`mt-10 rounded-[4px] px-5 py-3.5 text-center font-mono text-label uppercase transition-colors ${
                r.featured ? 'bg-signal text-void hover:bg-white' : 'text-white ring-1 ring-white/25 hover:bg-white hover:text-void'
              }`}
            >
              {r.cta}
            </a>
          </li>
        ))}
      </ol>
    </section>
  );
}
