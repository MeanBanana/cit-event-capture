/**
 * Every word on the page. The attack scenes are illustrations made for this
 * site; the statistics are sourced in `sources` and shown in the footer.
 */

export const brand = {
  name: 'Argus Shield',
  wordmark: 'ARGUS SHIELD',
  /** The root admin's address — the contact form drafts mail to it. */
  email: 'carel.vonronge@gmail.com',
  /** The root admin's web console (served from web/admin-console). */
  adminHref: '/admin/',
};

export const nav = [
  {label: 'The attack', href: '#attack'},
  {label: 'How it works', href: '#pipeline'},
  {label: 'Roles', href: '#roles'},
  {label: 'Get the app', href: '#download'},
  {label: 'Contact', href: '#contact'},
];

export const hero = {
  title: 'ARGUS SHIELD',
  kicker: 'Every phone, a witness',
  site: 'N12 Northbound · 26.18°S 28.31°E',
  veilTop: 'CAM 04 · Signal lost',
  veilCta: 'Scroll to restore the feed',
};

export const intro = {
  eyebrow: 'The attack',
  heading: 'Ninety seconds. A highway full of witnesses.',
  body: 'Cash-in-transit gangs strike fast and are gone before help arrives. But the people stuck in the traffic have phones — and Argus turns what they film into evidence.',
};

export const log = [
  {tag: '05:41', title: 'The convoy', body: 'A cash van joins the morning traffic on the N12. Nothing looks wrong yet.', image: '/media/cards/s1.webp'},
  {tag: '05:42', title: 'The ambush', body: 'Two cars box it in. Rifles come out. Shots are fired at the cab.', image: '/media/cards/s2.webp'},
  {tag: '05:43', title: 'The witness', body: 'A driver three cars back opens Argus and hits record. GPS and time are stamped automatically.', image: '/media/cards/s3.webp'},
  {tag: '05:50', title: 'Argus sees', body: 'Every person, vehicle, weapon and plate in the footage — waiting for the investigator before the scene is even taped off.', image: '/media/cards/s4.webp'},
];

/** Steps from a citizen's phone to an investigator's case file, in drawing order. */
export const pipeline = {
  eyebrow: 'How it works',
  heading: 'From a shaky video to a case file — drawn as you scroll.',
  counterLabel: 'Frames analysed',
  /** One minute of footage at 30 frames a second. */
  frames: 1800,
  legs: [
    {step: 'Capture', title: 'Any phone at the scene', body: 'Film live or upload from the gallery. Location and time are added on their own — the witness just points and shoots.'},
    {step: 'Upload', title: 'Straight to Argus, securely', body: 'The report travels encrypted to Argus. Citizens never see what the AI finds, so nothing can tip off a suspect.'},
    {step: 'Analyse', title: 'The AI watches every frame', body: 'People, vehicles, weapons and number plates are found and cropped — with clothing colours, faces and who was holding what.'},
    {step: 'Case', title: 'One picture of the attack', body: 'The same person or car seen in different videos is merged into one entry, so investigators see the whole attack in one case file.'},
  ],
};

export const roles = {
  eyebrow: 'Roles',
  heading: 'Three people. One picture.',
  note: 'One app for citizens and police · a web console for the root admin',
  items: [
    {
      name: 'Citizen',
      stat: '3',
      unit: 'taps to report',
      rings: 2,
      lines: ['Film live or upload what you saw', 'Location and time stamped for you', 'Follow your report’s progress', 'English, Afrikaans and isiZulu'],
      cta: 'Get the app',
      href: '#download',
    },
    {
      name: 'Investigator',
      stat: '1',
      unit: 'case file per attack',
      rings: 4,
      lines: ['AI summary of every person, car and weapon', 'Crops and footage, frame by frame', 'Matches suggested across reports', 'Private chat with the case team'],
      cta: 'Request access',
      href: '#contact',
      featured: true,
    },
    {
      name: 'Admin',
      stat: '24/7',
      unit: 'oversight',
      rings: 3,
      lines: ['Accept, reject or merge every report', 'Open cases and assign investigators', 'Correct the AI when it gets it wrong', 'Live overview and full activity log'],
      cta: 'Admin login',
      href: '/admin/',
    },
  ],
};

/** The Android app download (Download.tsx). The APK file itself goes in
 *  public/downloads/ (see README: "Putting a new APK on the website"). */
export const download = {
  eyebrow: 'Get the app',
  heading: 'Argus Shield on your phone.',
  body: 'Free for citizens. Film or upload what you saw, and Argus does the rest. Android phones only for now.',
  apk: '/downloads/argus-shield.apk',
  version: '1.0.0',
  size: 'about 25 MB',
  steps: [
    'Tap Download and wait for it to finish.',
    'Open the file (from the notification or your Downloads).',
    'If asked, allow your browser to "Install unknown apps", then tap Install.',
    'Open Argus Shield and register as a citizen.',
  ],
};

export const contact = {
  eyebrow: 'Contact',
  heading: 'Bring Argus to your station.',
  body: 'We are piloting Argus Shield with police stations and cash-in-transit security teams. Tell us who you are and we’ll be in touch.',
  stats: [
    {value: '200+', label: 'CIT heists in a year', source: 'CITASA'},
    {value: '29', label: 'in one quarter alone', source: 'SAPS, Oct–Dec 2024'},
    {value: '1', label: 'phone is enough to help', source: 'Argus Shield'},
  ],
  roles: ['Police station', 'CIT security company', 'Investigator', 'Citizen', 'Other'],
};

export const sources = [
  {
    label: 'Daily News — Dr Chris de Kock commends SAPS efforts in combating cash-in-transit robberies (Aug 2025)',
    href: 'https://dailynews.co.za/news/2025-08-19-dr-chris-de-kock-commends-saps-efforts-in-combating-cash-in-transit-robberies/',
  },
];
