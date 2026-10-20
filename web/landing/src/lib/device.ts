/**
 * What kind of device is looking at the page, for the Download section:
 * the app is an Android phone app, so only Android phones get the button.
 *
 * Uses User-Agent Client Hints where the browser has them (Chrome on
 * Android: platform "Android", mobile true) and the user-agent text
 * otherwise. Android TABLETS leave "Mobile" out of their user agent.
 * Chrome's "Desktop site" mode pretends to be a computer, so it looks like
 * a desktop here (the page tells people to switch it off).
 */
export type DeviceKind = 'android-phone' | 'android-tablet' | 'ios' | 'desktop';

type UAData = {mobile?: boolean; platform?: string};

export function detectDevice(): DeviceKind {
  if (typeof navigator === 'undefined') return 'desktop';
  const ua = navigator.userAgent || '';
  const hints = (navigator as Navigator & {userAgentData?: UAData}).userAgentData;
  const android = hints?.platform === 'Android' || /Android/i.test(ua);
  if (android) {
    const mobile = hints?.mobile ?? /Mobile/i.test(ua);
    return mobile ? 'android-phone' : 'android-tablet';
  }
  // iPadOS reports itself as a Mac, but Macs have no touch screen
  if (/iPhone|iPad|iPod/i.test(ua) || (/Macintosh/i.test(ua) && navigator.maxTouchPoints > 1)) {
    return 'ios';
  }
  return 'desktop';
}
