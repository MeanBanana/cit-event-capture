import {useState, type FormEvent} from 'react';
import {brand, contact} from '../content';
import {useReveals} from '../hooks/useReveals';

type Status = 'idle' | 'invalid' | 'sent';

/**
 * Contact. The numbers behind the problem on one side, a short form on the
 * other; the form hands a drafted message to the visitor's mail app.
 */
export function Contact() {
  const ref = useReveals<HTMLElement>();
  const [status, setStatus] = useState<Status>('idle');

  const onSubmit = (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault();
    const form = e.currentTarget;
    if (!form.checkValidity()) {
      setStatus('invalid');
      form.reportValidity();
      return;
    }
    const data = new FormData(form);
    const subject = encodeURIComponent(`Argus Shield: ${String(data.get('role'))}`);
    const body = encodeURIComponent(
      `Name: ${String(data.get('name'))}\nEmail: ${String(data.get('email'))}\nOrganisation: ${String(data.get('org') || '-')}\nI am: ${String(data.get('role'))}`,
    );
    window.location.href = `mailto:${brand.email}?subject=${subject}&body=${body}`;
    setStatus('sent');
  };

  const field =
    'w-full rounded-[4px] bg-white/[0.04] px-4 py-3.5 text-body text-white ring-1 ring-white/15 outline-none placeholder:text-steel/40 focus:ring-signal user-invalid:ring-red-400/70';

  return (
    <section ref={ref} id="contact" aria-labelledby="contact-title" className="relative overflow-hidden bg-void px-4 pb-28 sm:px-6 md:px-[6vw] md:pb-40">
      {/* Sodium streetlight glow at the bottom edge — the hero's road, bookended. */}
      <div aria-hidden="true" className="pointer-events-none absolute -bottom-[62vw] left-1/2 size-[90vw] -translate-x-1/2 rounded-full bg-[radial-gradient(circle_at_50%_30%,rgba(255,171,64,0.28),rgba(255,171,64,0.05)_55%,transparent_70%)]" />

      <div className="relative grid gap-12 border-t border-white/10 pt-20 md:grid-cols-2 md:gap-16 md:pt-28">
        <div data-reveal>
          <p className="font-mono text-label text-signal uppercase">{contact.eyebrow}</p>
          <h2 id="contact-title" className="mt-4 font-display text-display text-white">
            {contact.heading}
          </h2>
          <p className="mt-5 max-w-[28rem] text-body text-steel/70">{contact.body}</p>

          <div className="mt-10 grid grid-cols-3 gap-2 md:gap-3">
            {contact.stats.map((s) => (
              <div key={s.label} className="brackets px-3 py-4 text-white/25">
                <span className="block font-display text-[1.5rem] text-white tabular-nums md:text-[2.25rem]">{s.value}</span>
                <span className="mt-2 block text-[0.8125rem] leading-snug text-steel/75">{s.label}</span>
                <span className="mt-2 block font-mono text-[0.5625rem] tracking-[0.14em] text-steel/45 uppercase">{s.source}</span>
              </div>
            ))}
          </div>
        </div>

        <form noValidate onSubmit={onSubmit} aria-describedby="contact-status" className="space-y-3" data-reveal>
          <label className="block">
            <span className="mb-1.5 block font-mono text-label text-steel/60 uppercase">Name</span>
            <input name="name" required autoComplete="name" placeholder="Your name" className={field} onInput={() => setStatus('idle')} />
          </label>
          <label className="block">
            <span className="mb-1.5 block font-mono text-label text-steel/60 uppercase">Email</span>
            <input name="email" type="email" required autoComplete="email" placeholder="you@station.gov.za" className={field} onInput={() => setStatus('idle')} />
          </label>
          <label className="block">
            <span className="mb-1.5 block font-mono text-label text-steel/60 uppercase">Station or company</span>
            <input name="org" autoComplete="organization" placeholder="Optional" className={field} />
          </label>
          <label className="block">
            <span className="mb-1.5 block font-mono text-label text-steel/60 uppercase">I am a</span>
            <select name="role" defaultValue={contact.roles[0]} className={`${field} appearance-none`}>
              {contact.roles.map((r) => (
                <option key={r} value={r} className="bg-void">
                  {r}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" className="mt-2 w-full rounded-[4px] bg-signal px-5 py-4 font-mono text-label text-void uppercase transition-colors hover:bg-white">
            Get in touch
          </button>
          <p id="contact-status" role="status" className="min-h-[1.25rem] text-[0.8125rem] text-steel/70">
            {status === 'invalid' && 'Your name and a valid email, please.'}
            {status === 'sent' && `Your mail app should be open with your message drafted. If not: ${brand.email}.`}
          </p>
        </form>
      </div>
    </section>
  );
}
