/**
 * Works out what kind of device is viewing the page, for the Download
 * section. It's a phone app, so only Android phones get the button.
 *
 * Uses User-Agent Client Hints when available (Chrome on Android reports
 * platform "Android", mobile true) and falls back to the UA string. Android
 * tablets leave "Mobile" out of their UA. Chrome's "Desktop site" mode
 * pretends to be a computer, so it'll look like a desktop here (the page
 * tells people to turn it off).
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
  // iPadOS claims to be a Mac, but Macs don't have touch screens
  if (/iPhone|iPad|iPod/i.test(ua) || (/Macintosh/i.test(ua) && navigator.maxTouchPoints > 1)) {
    return 'ios';
  }
  return 'desktop';
}
