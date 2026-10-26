import {useEffect, useState} from 'react';
import QRCode from 'qrcode';
import {download} from '../content';
import {useReveals} from '../hooks/useReveals';
import {apkDownloadEnabled} from '../lib/apk-switch';
import {detectDevice, type DeviceKind} from '../lib/device';

/**
 * Get the app. The APK is only offered on Android phones:
 *   Android phone   download button and the four install steps
 *   computer        a QR code so you can open this on your phone
 *   Android tablet  "made for phones"
 *   iPhone/iPad     "Android only for now"
 * Netlify also guards the file itself (netlify/edge-functions/apk-guard.ts),
 * so you can't just copy the link onto another device.
 *
 * Root can also switch the download off from the admin console (free
 * Supabase, big demos). Then everyone just gets a "paused" notice.
 */
export function Download() {
  const ref = useReveals<HTMLElement>();
  const [device, setDevice] = useState<DeviceKind>('desktop');
  const [qr, setQr] = useState<string | null>(null);
  // null while we're still asking Supabase
  const [enabled, setEnabled] = useState<boolean | null>(null);

  useEffect(() => {
    setDevice(detectDevice());
    const abort = new AbortController();
    apkDownloadEnabled(abort.signal).then((on) => {
      if (!abort.signal.aborted) setEnabled(on);
    });
    return () => abort.abort();
  }, []);

  const paused = enabled === false;
  const canDownload = device === 'android-phone' && enabled === true;

  useEffect(() => {
    if (device === 'android-phone' || paused) return;
    const url = `${window.location.origin}/#download`;
    QRCode.toDataURL(url, {margin: 1, width: 360, color: {dark: '#070b14', light: '#ffffff'}})
      .then(setQr)
      .catch(() => setQr(null));
  }, [device, paused]);

  const notice: Record<Exclude<DeviceKind, 'android-phone'> | 'paused' | 'checking', {title: string; body: string}> = {
    paused: {
      title: 'Downloads are paused',
      body: 'The app download is switched off for the moment. Check back later to get Argus Shield on your Android phone.',
    },
    checking: {
      title: 'One moment',
      body: 'Checking whether the download is available.',
    },
    desktop: {
      title: 'Open this on your Android phone',
      body: 'The app installs on Android phones only. Scan the code with your phone’s camera to open this page there, then tap Download. On your phone already? Switch off “Desktop site” in your browser menu.',
    },
    'android-tablet': {
      title: 'Made for phones',
      body: 'Argus Shield is built for Android phones, so it can’t be downloaded on a tablet. Open this page on your Android phone instead.',
    },
    ios: {
      title: 'Android only for now',
      body: 'Argus Shield isn’t available for iPhone or iPad yet. Open this page on an Android phone to download it.',
    },
  };

  const noticeKey = paused ? 'paused' : device === 'android-phone' ? 'checking' : device;

  return (
    <section ref={ref} id="download" aria-labelledby="download-title" className="relative bg-void px-4 pb-28 sm:px-6 md:px-[6vw] md:pb-40">
      <div className="grid gap-12 border-t border-white/10 pt-20 md:grid-cols-2 md:gap-16 md:pt-28">
        <div data-reveal>
          <p className="font-mono text-label text-signal uppercase">{download.eyebrow}</p>
          <h2 id="download-title" className="mt-4 font-display text-display text-white">
            {download.heading}
          </h2>
          <p className="mt-5 max-w-[28rem] text-body text-steel/70">{download.body}</p>

          {canDownload ? (
            <div className="mt-10">
              <a
                href={download.apk}
                download="argus-shield.apk"
                className="flex w-full items-center justify-center gap-3 rounded-[4px] bg-signal px-5 py-4 font-mono text-label text-void uppercase transition-colors hover:bg-white sm:w-auto sm:inline-flex"
              >
                <AndroidIcon className="size-5" />
                Download for Android
              </a>
              <p className="mt-3 font-mono text-[0.625rem] tracking-[0.14em] text-steel/50 uppercase">
                Version {download.version} · {download.size} · APK
              </p>
            </div>
          ) : (
            <div className="mt-10">
              <button
                type="button"
                disabled
                aria-describedby="download-notice"
                className="flex w-full cursor-not-allowed items-center justify-center gap-3 rounded-[4px] bg-white/10 px-5 py-4 font-mono text-label text-white/40 uppercase sm:w-auto sm:inline-flex"
              >
                <AndroidIcon className="size-5" />
                {paused ? 'Download · Paused' : 'Download · Android phones only'}
              </button>
              <div id="download-notice" className="mt-5 max-w-[28rem] border-l-2 border-signal pl-4">
                <p className="font-display text-[0.9375rem] tracking-[0.06em] text-white uppercase">{notice[noticeKey].title}</p>
                <p className="mt-2 text-[0.9375rem] leading-relaxed text-steel/70">{notice[noticeKey].body}</p>
              </div>
            </div>
          )}
        </div>

        <div data-reveal>
          {canDownload ? (
            <ol className="space-y-4">
              {download.steps.map((step, i) => (
                <li key={step} className="flex gap-4">
                  <span className="font-mono text-label text-signal">0{i + 1}</span>
                  <span className="text-body text-steel/80">{step}</span>
                </li>
              ))}
            </ol>
          ) : device === 'desktop' && !paused && qr ? (
            <figure className="flex flex-col items-start gap-4 md:items-center">
              <div className="brackets p-4 text-white/30">
                <img src={qr} alt="QR code that opens this page on your phone" width={220} height={220} className="size-[220px] rounded-[4px]" />
              </div>
              <figcaption className="font-mono text-label text-steel/60 uppercase">Scan with your Android phone</figcaption>
            </figure>
          ) : null}
        </div>
      </div>
    </section>
  );
}

function AndroidIcon({className = ''}: {className?: string}) {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true" className={className} fill="currentColor">
      <path d="M17.6 9.48l1.84-3.18a.38.38 0 0 0-.66-.38l-1.86 3.22a11.4 11.4 0 0 0-9.84 0L5.22 5.92a.38.38 0 0 0-.66.38L6.4 9.48A10.8 10.8 0 0 0 1 18h22a10.8 10.8 0 0 0-5.4-8.52zM7 15.25a1.25 1.25 0 1 1 0-2.5 1.25 1.25 0 0 1 0 2.5zm10 0a1.25 1.25 0 1 1 0-2.5 1.25 1.25 0 0 1 0 2.5z" />
    </svg>
  );
}
