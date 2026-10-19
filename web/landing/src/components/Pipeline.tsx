import {useEffect, useRef, useState} from 'react';
import {pipeline} from '../content';
import {clamp, easeOutCubic, pinProgress, range} from '../lib/math';
import {onFrame} from '../lib/scroll';

/**
 * Phone → case file, drawn as you scroll. The section pins while the four
 * legs of a report's journey ink themselves one after another, a pulse
 * riding the leg being drawn; the frames-analysed counter ticks up while the
 * AI leg is drawn.
 */

const SECTION_VH = 380;
const WINDOW = [0.06, 0.92] as const;

const PHONE = {cx: 190, cy: 360};
const CLOUD = {cx: 520, cy: 170};
const AI = {cx: 860, cy: 350};
const CASE = {cx: 1075, cy: 175};

const LEGS = [
  // Capture: the witness films — a lap round the phone.
  `M${PHONE.cx} ${PHONE.cy - 118} a118 118 0 1 1 -0.1 0 a118 118 0 0 1 98 52`,
  // Upload to Argus.
  `M${PHONE.cx + 98} ${PHONE.cy - 66} C 330 190, 400 160, ${CLOUD.cx - 82} ${CLOUD.cy + 6}`,
  // Analyse: down to the AI, then a full scan round it.
  `M${CLOUD.cx + 82} ${CLOUD.cy + 6} C 700 170, 800 160, ${AI.cx} ${AI.cy - 108} a108 108 0 1 1 -0.1 0.2 a108 108 0 0 1 96 50`,
  // Case: the findings are filed for the investigators.
  `M${AI.cx + 96} ${AI.cy - 58} C 1010 270, 1060 270, ${CASE.cx} ${CASE.cy + 62}`,
];

const NODE_LABEL = 'IBM Plex Mono, monospace';

export function Pipeline() {
  const rootRef = useRef<HTMLElement>(null);
  const legRefs = useRef<SVGPathElement[]>([]);
  const pulseRef = useRef<SVGGElement>(null);
  const framesRef = useRef<HTMLSpanElement>(null);
  const [leg, setLeg] = useState(0);

  useEffect(() => {
    let lastP = -1;
    let current = 0;
    return onFrame(() => {
      const root = rootRef.current;
      if (!root) return;
      const {p, rect, vh} = pinProgress(root);
      if (rect.bottom < 0 || rect.top > vh) return;
      if (Math.abs(p - lastP) < 0.00005) return;
      lastP = p;

      const u = range(p, ...WINDOW) * LEGS.length;
      const s = clamp(Math.floor(u), 0, LEGS.length - 1);
      if (s !== current) {
        current = s;
        setLeg(s);
      }
      legRefs.current.forEach((path, i) => {
        const k = easeOutCubic(clamp(u - i));
        path.style.strokeDashoffset = String(1 - k);
        if (i === s) {
          const pt = path.getPointAtLength(path.getTotalLength() * k);
          pulseRef.current!.setAttribute('transform', `translate(${pt.x} ${pt.y})`);
        }
      });
      const scan = easeOutCubic(clamp(u - 2));
      framesRef.current!.textContent = Math.round(scan * pipeline.frames).toLocaleString('en-US');
    });
  }, []);

  const current = pipeline.legs[leg];

  return (
    <section ref={rootRef} id="pipeline" aria-labelledby="pipeline-title" className="relative bg-void" style={{height: `${SECTION_VH}svh`}}>
      <div className="sticky top-0 flex h-screen-s flex-col overflow-hidden px-4 pt-20 pb-8 sm:px-6 md:px-[6vw] md:pt-24">
        <div className="flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
          <div>
            <p className="font-mono text-label text-signal uppercase">{pipeline.eyebrow}</p>
            <h2 id="pipeline-title" className="mt-3 max-w-[22ch] font-display text-display text-white">
              {pipeline.heading}
            </h2>
          </div>
          <p className="font-mono text-label text-steel/60 uppercase" aria-live="off">
            {pipeline.counterLabel} <span ref={framesRef} className="text-white tabular-nums">0</span>
          </p>
        </div>

        <div className="relative flex min-h-0 flex-1 items-center">
          <svg viewBox="0 0 1200 600" className="h-auto max-h-full w-full" role="img" aria-label="A report's journey in four legs: filmed on a phone, uploaded to Argus, analysed by the AI, filed in a case.">
            <defs>
              <radialGradient id="node-glow">
                <stop offset="0.6" stopColor="#ffab40" stopOpacity="0.22" />
                <stop offset="1" stopColor="#ffab40" stopOpacity="0" />
              </radialGradient>
              <radialGradient id="eye-glow">
                <stop offset="0.5" stopColor="#4cc3ff" stopOpacity="0.3" />
                <stop offset="1" stopColor="#4cc3ff" stopOpacity="0" />
              </radialGradient>
            </defs>

            {/* Faint grid, like a camera's framing guides. */}
            <g stroke="#fff" strokeOpacity="0.04">
              {Array.from({length: 13}, (_, i) => (
                <line key={`v${i}`} x1={i * 100} y1="0" x2={i * 100} y2="600" />
              ))}
              {Array.from({length: 7}, (_, i) => (
                <line key={`h${i}`} x1="0" y1={i * 100} x2="1200" y2={i * 100} />
              ))}
            </g>

            {/* Phone */}
            <circle cx={PHONE.cx} cy={PHONE.cy} r="70" fill="url(#node-glow)" />
            <rect x={PHONE.cx - 26} y={PHONE.cy - 46} width="52" height="92" rx="9" fill="#0e1626" stroke="#c9ced8" strokeWidth="2" />
            <circle cx={PHONE.cx} cy={PHONE.cy + 30} r="6" fill="#f35c68" />
            <rect x={PHONE.cx - 8} y={PHONE.cy - 40} width="16" height="3" rx="1.5" fill="#c9ced8" opacity="0.6" />

            {/* Cloud */}
            <circle cx={CLOUD.cx} cy={CLOUD.cy} r="76" fill="url(#node-glow)" />
            <path
              d={`M${CLOUD.cx - 46} ${CLOUD.cy + 26} a24 24 0 0 1 2 -48 a32 32 0 0 1 60 -8 a22 22 0 0 1 32 22 a18 18 0 0 1 -4 34 z`}
              fill="#0e1626"
              stroke="#c9ced8"
              strokeWidth="2"
            />
            <path d={`M${CLOUD.cx} ${CLOUD.cy + 14} v-24 m-9 9 l9 -9 l9 9`} fill="none" stroke="#ffab40" strokeWidth="2.5" strokeLinecap="round" strokeLinejoin="round" />

            {/* The AI: an eye — Argus, the hundred-eyed watchman. */}
            <circle cx={AI.cx} cy={AI.cy} r="80" fill="url(#eye-glow)" />
            <path d={`M${AI.cx - 52} ${AI.cy} Q ${AI.cx} ${AI.cy - 44} ${AI.cx + 52} ${AI.cy} Q ${AI.cx} ${AI.cy + 44} ${AI.cx - 52} ${AI.cy} z`} fill="#0e1626" stroke="#c9ced8" strokeWidth="2" />
            <circle cx={AI.cx} cy={AI.cy} r="15" fill="#4cc3ff" />
            <circle cx={AI.cx} cy={AI.cy} r="6" fill="#070b14" />

            {/* Case file */}
            <circle cx={CASE.cx} cy={CASE.cy} r="72" fill="url(#node-glow)" />
            <path
              d={`M${CASE.cx - 42} ${CASE.cy - 26} h28 l8 10 h48 v50 h-84 z`}
              fill="#0e1626"
              stroke="#c9ced8"
              strokeWidth="2"
              strokeLinejoin="round"
            />
            <path d={`M${CASE.cx - 24} ${CASE.cy + 6} h48 M${CASE.cx - 24} ${CASE.cy + 18} h32`} stroke="#ffab40" strokeWidth="2.5" strokeLinecap="round" />

            {/* Ghost of the whole route, then the inked legs over it. */}
            {LEGS.map((d, i) => (
              <path key={`g${i}`} d={d} fill="none" stroke="#fff" strokeOpacity="0.08" strokeWidth="1.5" strokeDasharray="3 6" />
            ))}
            {LEGS.map((d, i) => (
              <path
                key={i}
                ref={(el) => {
                  if (el) legRefs.current[i] = el;
                }}
                d={d}
                pathLength={1}
                fill="none"
                stroke={i === 2 ? '#4cc3ff' : '#ffab40'}
                strokeWidth="2"
                strokeLinecap="round"
                strokeDasharray="1 1"
                strokeDashoffset="1"
              />
            ))}

            <g ref={pulseRef} transform={`translate(${PHONE.cx} ${PHONE.cy - 118})`}>
              <circle r="12" fill="#ffab40" opacity="0.25" />
              <circle r="4.5" fill="#fff" />
            </g>

            <g fontFamily={NODE_LABEL} fontSize="13" letterSpacing="2" fill="#8b93a3" textAnchor="middle">
              <text x={PHONE.cx} y={PHONE.cy + 160}>WITNESS PHONE</text>
              <text x={CLOUD.cx} y={CLOUD.cy - 96}>ARGUS CLOUD</text>
              <text x={AI.cx} y={AI.cy + 150}>AI ANALYSIS</text>
              <text x={CASE.cx} y={CASE.cy - 92}>CASE FILE</text>
            </g>
          </svg>
        </div>

        {/* Current leg. */}
        <div className="grid gap-4 border-t border-white/10 pt-5 md:grid-cols-[auto_1fr_auto] md:items-end md:gap-10">
          <p className="font-mono text-label text-signal uppercase">
            {current.step} · Step {leg + 1}/{pipeline.legs.length}
          </p>
          <div key={leg} className="animate-[leg-in_0.6s_cubic-bezier(0.2,0.7,0.1,1)]" aria-live="polite">
            <h3 className="font-display text-[1.125rem] tracking-[0.08em] text-white uppercase md:text-[1.375rem]">{current.title}</h3>
            <p className="mt-1.5 max-w-[40rem] text-body text-steel/70">{current.body}</p>
          </div>
          <div className="flex gap-1.5" aria-hidden="true">
            {pipeline.legs.map((_, i) => (
              <span key={i} className={`h-1 w-8 rounded-full transition-colors duration-500 ${i <= leg ? 'bg-signal' : 'bg-white/15'}`} />
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
