import {useEffect, useRef} from 'react';
import {hero} from '../content';
import {useReducedMotion} from '../hooks/useReducedMotion';
import {clamp, easeOutCubic, lerp, pinProgress, range} from '../lib/math';
import {onFrame} from '../lib/scroll';
import {CUT_SIZE, DETECTIONS, type Cut, type Detection, type LayerName} from '../scene';

/**
 * The ambush, seen from a witness's car. Six illustrated layers cut from one
 * scene, stacked and pinned; one scroll range moves each at its own rate:
 *
 *   0.00 – 0.18  "signal lost" static clears off the camera feed
 *   0.04 – 0.50  the cash van rolls up the highway into view
 *   0.08 – 0.50  ARGUS SHIELD resolves above the road
 *   0.16 – 0.42  the robbers' cars and gunmen close in — shots are fired
 *   0.26 – 0.50  Argus boxes every person, vehicle, weapon and plate
 *   0.40 – 0.66  the windscreen, the phone and the dashboard rise around
 *                the view — you are the witness, filming
 *   0.72 – 1.00  everything tilts away upward and the dashboard swallows
 *                the frame to black, which is where the page continues
 *
 * A camera HUD rides on top: recording clock, live detection counts,
 * location. The AI boxes are drawn on a canvas from src/scene.ts, mapped
 * through each layer's current transform so they stay locked to the scene.
 */

const STAGE_VH = 440;

const ORDER: LayerName[] = ['sky', 'van', 'ambush', 'frame', 'phone', 'ground'];

/** All layers share one crop (object-cover, centred), so they stay registered. */
const FIT = 'absolute inset-0 size-full object-cover object-center';

const COLOURS: Record<Detection['kind'], string> = {
  person: '#4cc3ff',
  vehicle: '#ffab40',
  weapon: '#f35c68',
  plate: '#ffffff',
};
const SCORES = [0.97, 0.93, 0.91, 0.88, 0.95, 0.9, 0.86, 0.94, 0.89, 0.92];

/** Bursts of fire: each gun fires a few quick rounds, then pauses. */
function firing(time: number, i: number) {
  const phase = (time / 1000 + i * 0.53) % 1.5;
  return phase < 0.45 && (phase * 1000) % 150 < 55;
}

export function Hero() {
  const rootRef = useRef<HTMLElement>(null);
  const layerRefs = useRef<Partial<Record<LayerName, HTMLDivElement>>>({});
  const veilRef = useRef<HTMLDivElement>(null);
  const staticRef = useRef<HTMLCanvasElement>(null);
  const aiRef = useRef<HTMLCanvasElement>(null);
  const titleRef = useRef<HTMLDivElement>(null);
  const hudRef = useRef<HTMLDivElement>(null);
  const clockRef = useRef<HTMLParagraphElement>(null);
  const countRef = useRef<HTMLParagraphElement>(null);
  const alertRef = useRef<HTMLParagraphElement>(null);
  const reduced = useReducedMotion();
  const reducedRef = useRef(reduced);
  reducedRef.current = reduced;

  // The AI canvas matches the screen (device pixels, capped at 2x).
  useEffect(() => {
    const c = aiRef.current!;
    const sync = () => {
      const dpr = Math.min(window.devicePixelRatio || 1, 2);
      c.width = Math.round(c.clientWidth * dpr);
      c.height = Math.round(c.clientHeight * dpr);
    };
    sync();
    const ro = new ResizeObserver(sync);
    ro.observe(c);
    return () => ro.disconnect();
  }, []);

  useEffect(() => {
    const ai = aiRef.current!;
    const actx = ai.getContext('2d')!;
    const noise = staticRef.current!;
    const nctx = noise.getContext('2d')!;
    const img = nctx.createImageData(noise.width, noise.height);
    const mobileQuery = window.matchMedia('(max-width: 767px)');

    // Where each layer is right now (translate in vh, scale about the centre).
    const pose: Record<LayerName, {y: number; s: number}> = {
      sky: {y: 0, s: 1}, van: {y: 0, s: 1}, ambush: {y: 0, s: 1},
      frame: {y: 0, s: 1}, phone: {y: 0, s: 1}, ground: {y: 0, s: 1},
    };
    let lastP = -1;
    let frame = 0;
    let boxesIn = 0;
    let shooting = false;

    const set = (name: LayerName, y: number, scale = 1, opacity = 1) => {
      pose[name] = {y, s: scale};
      const el = layerRefs.current[name];
      if (!el) return;
      el.style.transform = `translate3d(0, ${y}vh, 0) scale(${scale})`;
      el.style.opacity = String(opacity);
    };

    /** A point in a layer image (fractions) -> CSS pixels on screen. */
    const toScreen = (cut: Cut, layer: LayerName, fx: number, fy: number, vw: number, vh: number) => {
      const {w: iw, h: ih} = CUT_SIZE[cut];
      const k = Math.max(vw / iw, vh / ih);
      let x = (vw - iw * k) / 2 + fx * iw * k;
      let y = (vh - ih * k) / 2 + fy * ih * k;
      const {y: ty, s} = pose[layer];
      x = vw / 2 + (x - vw / 2) * s;
      y = vh / 2 + (y - vh / 2) * s + (ty * vh) / 100;
      return [x, y] as const;
    };

    const drawAI = (p: number, time: number) => {
      const vw = ai.clientWidth;
      const vh = ai.clientHeight;
      const dpr = ai.width / Math.max(1, vw);
      actx.setTransform(dpr, 0, 0, dpr, 0, 0);
      actx.clearRect(0, 0, vw, vh);
      const visible = 1 - range(p, 0.66, 0.74);
      if (visible <= 0) return;
      const cut: Cut = mobileQuery.matches ? 'm' : 'd';
      const dets = DETECTIONS[cut];
      const motion = !reducedRef.current;

      // Shots: muzzle flashes and tracers while the gunmen are in view.
      const gunsLive = range(p, 0.2, 0.3) * (1 - range(p, 0.6, 0.7));
      shooting = false;
      if (motion && gunsLive > 0) {
        let lit = 0;
        dets.forEach((d, i) => {
          if (d.kind !== 'weapon' || d.mx === undefined || d.my === undefined) return;
          if (!firing(time, i)) return;
          lit++;
          const [x, y] = toScreen(cut, d.layer, d.mx, d.my, vw, vh);
          const dir = d.dir ?? 1;
          const r = Math.max(14, vw * 0.018) * pose[d.layer].s;
          actx.globalAlpha = gunsLive;
          const g = actx.createRadialGradient(x, y, 0, x, y, r * 2.2);
          g.addColorStop(0, 'rgba(255,255,235,1)');
          g.addColorStop(0.25, 'rgba(255,205,100,0.9)');
          g.addColorStop(1, 'rgba(255,120,30,0)');
          actx.fillStyle = g;
          actx.beginPath();
          actx.arc(x, y, r * 2.2, 0, Math.PI * 2);
          actx.fill();
          actx.fillStyle = 'rgba(255,245,210,0.95)';
          actx.beginPath();
          actx.moveTo(x, y - r * 0.18);
          actx.lineTo(x + dir * r * 2.6, y + (Math.random() - 0.5) * r * 0.4);
          actx.lineTo(x, y + r * 0.18);
          actx.fill();
          // tracer
          const len = vw * (0.06 + Math.random() * 0.05);
          const start = r * 3 + Math.random() * vw * 0.04;
          actx.strokeStyle = 'rgba(255,220,150,0.7)';
          actx.lineWidth = 1.5;
          actx.beginPath();
          actx.moveTo(x + dir * start, y);
          actx.lineTo(x + dir * (start + len), y + (Math.random() - 0.5) * 6);
          actx.stroke();
        });
        if (lit) {
          shooting = true;
          actx.globalAlpha = 0.07 * lit * gunsLive;
          actx.fillStyle = '#ffa040';
          actx.fillRect(0, 0, vw, vh);
        }
        actx.globalAlpha = 1;
      }

      // Scan line sweeps once as the AI starts looking.
      const sweep = range(p, 0.24, 0.36);
      if (sweep > 0 && sweep < 1) {
        const y = sweep * vh;
        const g = actx.createLinearGradient(0, y - 60, 0, y);
        g.addColorStop(0, 'rgba(76,195,255,0)');
        g.addColorStop(1, 'rgba(76,195,255,0.28)');
        actx.fillStyle = g;
        actx.fillRect(0, y - 60, vw, 60);
        actx.fillStyle = 'rgba(160,225,255,0.8)';
        actx.fillRect(0, y, vw, 1.5);
      }

      // Boxes: each detection snaps in, a little after the one before.
      let count = 0;
      const font = vw < 768 ? 9 : 11;
      actx.font = `500 ${font}px "IBM Plex Mono", monospace`;
      actx.textBaseline = 'middle';
      dets.forEach((d, i) => {
        const k = easeOutCubic(range(p, 0.27 + i * 0.018, 0.31 + i * 0.018)) * visible;
        if (k <= 0) return;
        count++;
        const [x0, y0] = toScreen(cut, d.layer, d.x, d.y, vw, vh);
        const [x1, y1] = toScreen(cut, d.layer, d.x + d.w, d.y + d.h, vw, vh);
        const cx = (x0 + x1) / 2;
        const cy = (y0 + y1) / 2;
        const grow = lerp(1.25, 1, k);
        const bx = cx - ((x1 - x0) / 2) * grow;
        const by = cy - ((y1 - y0) / 2) * grow;
        const bw = (x1 - x0) * grow;
        const bh = (y1 - y0) * grow;
        const col = COLOURS[d.kind];
        actx.globalAlpha = k;
        actx.strokeStyle = col;
        actx.lineWidth = 1.5;
        actx.strokeRect(bx, by, bw, bh);
        // heavier corners
        const c = Math.min(16, bw / 4, bh / 4);
        actx.lineWidth = 3;
        actx.beginPath();
        for (const [ax, ay, sx, sy] of [
          [bx, by, 1, 1],
          [bx + bw, by, -1, 1],
          [bx, by + bh, 1, -1],
          [bx + bw, by + bh, -1, -1],
        ] as const) {
          actx.moveTo(ax + sx * c, ay);
          actx.lineTo(ax, ay);
          actx.lineTo(ax, ay + sy * c);
        }
        actx.stroke();
        if (d.kind !== 'plate' || vw >= 768) {
          const label = `${d.label.toUpperCase()}  ${SCORES[i % SCORES.length].toFixed(2)}`;
          const tw = actx.measureText(label).width + 10;
          const ly = by - font - 6 < 0 ? by + bh : by - font - 6;
          actx.fillStyle = col;
          actx.fillRect(bx - 0.75, ly, tw, font + 6);
          actx.fillStyle = '#070b14';
          actx.fillText(label, bx + 4, ly + (font + 6) / 2 + 0.5);
        }
        actx.globalAlpha = 1;
      });
      if (count !== boxesIn) {
        boxesIn = count;
        const shown = dets.slice(0, count);
        const n = (kind: Detection['kind']) => shown.filter((d) => d.kind === kind).length;
        countRef.current!.textContent = `${n('person')} people · ${n('vehicle')} vehicles · ${n('weapon')} weapons`;
      }
    };

    return onFrame((time) => {
      const root = rootRef.current;
      if (!root) return;
      const {p, rect} = pinProgress(root);
      if (rect.bottom < 0) return;
      frame++;

      // "Signal lost" static flickers while the veil is up.
      const veil = 1 - range(p, 0, 0.18);
      if (veil > 0.001 && (frame % 2 === 0 || lastP < 0)) {
        const data = img.data;
        for (let i = 0; i < data.length; i += 4) {
          const v = reducedRef.current ? 40 : Math.random() * 255;
          data[i] = data[i + 1] = data[i + 2] = v;
          data[i + 3] = 255;
        }
        nctx.putImageData(img, 0, 0);
      }

      // The AI layer animates every frame (shots), not only on scroll.
      drawAI(p, time);
      alertRef.current!.style.opacity = shooting ? '1' : String(Math.max(0, Number(alertRef.current!.style.opacity || 0) - 0.04));

      if (Math.abs(p - lastP) < 0.00005) return;
      lastP = p;

      const exit = range(p, 0.72, 1);
      const settle = easeOutCubic(range(p, 0, 0.5));

      // Veil clears upward.
      veilRef.current!.style.opacity = String(veil);
      veilRef.current!.style.transform = `translate3d(0, ${-range(p, 0, 0.18) * 24}vh, 0) scale(${1 + range(p, 0, 0.18) * 0.25})`;

      // Far → near, each faster than the one behind it.
      set('sky', lerp(0, -6, p), lerp(1.14, 1, settle));
      const rise = easeOutCubic(range(p, 0.04, 0.5));
      set('van', lerp(34, 0, rise) - exit * 12, lerp(0.92, 1, rise));
      const close = easeOutCubic(range(p, 0.16, 0.42));
      set('ambush', lerp(14, 0, close) - exit * 26, 1, close);
      const rim = easeOutCubic(range(p, 0.4, 0.62));
      set('frame', -exit * 44, lerp(1.6, 1, rim), rim);
      const up = easeOutCubic(range(p, 0.46, 0.66));
      set('phone', lerp(28, 0, up) - exit * 58, 1, clamp(up * 2));
      const dash = easeOutCubic(range(p, 0.44, 0.64));
      set('ground', lerp(36, 0, dash) - exit * 78);

      // Title: resolves (tracking closes in), then yields to the scene.
      const tIn = easeOutCubic(range(p, 0.08, 0.24));
      const tOut = range(p, 0.38, 0.48);
      const title = titleRef.current!;
      title.style.opacity = String(tIn * (1 - tOut));
      title.style.letterSpacing = `${lerp(0.55, 0.2, tIn)}em`;
      title.style.transform = `translate3d(0, ${-p * 6}vh, 0)`;
      title.style.filter = tIn < 0.99 ? `blur(${(1 - tIn) * 10}px)` : '';

      // Camera HUD.
      hudRef.current!.style.opacity = String(range(p, 0.02, 0.1) * (1 - range(p, 0.66, 0.74)));
      const secs = 5 * 3600 + 41 * 60 + 30 + p * 150;
      clockRef.current!.textContent = `${String(Math.floor(secs / 3600)).padStart(2, '0')}:${String(Math.floor((secs % 3600) / 60)).padStart(2, '0')}:${String(Math.floor(secs % 60)).padStart(2, '0')}`;
    });
  }, []);

  const layer = (name: LayerName) => (
    <div
      key={name}
      ref={(el) => {
        if (el) layerRefs.current[name] = el;
      }}
      className="absolute inset-0 will-change-transform"
    >
      <picture>
        <source media="(max-width: 767px)" srcSet={`/layers/m/${name}.webp`} />
        <img src={`/layers/d/${name}.webp`} alt="" aria-hidden="true" className={FIT} decoding="async" fetchPriority={name === 'sky' ? 'high' : 'auto'} />
      </picture>
      {/* The dashboard carries a black apron below it, so when it climbs it
          fills the screen and hands straight over to the page below. */}
      {name === 'ground' && <div className="absolute inset-x-0 top-full h-[110vh] bg-void" />}
    </div>
  );

  return (
    <section id="top" ref={rootRef} aria-label="A cash-in-transit ambush, filmed by a witness and analysed by Argus" className="relative" style={{height: `${STAGE_VH}svh`}}>
      <div className="sticky top-0 h-screen-s overflow-hidden bg-void">
        {ORDER.slice(0, 3).map((n) => layer(n))}

        {/* Title sits above the road, in front of the van. */}
        <div ref={titleRef} className="pointer-events-none absolute inset-x-0 top-[17%] px-2 text-center md:top-[13%]" style={{opacity: 0}}>
          <h1 className="font-display text-hero whitespace-nowrap text-white [text-shadow:0_4px_40px_rgb(0_0_0/0.6)]" style={{marginRight: '-0.2em'}}>
            {hero.title}
          </h1>
          <p className="mt-4 font-mono text-label text-signal uppercase">{hero.kicker}</p>
        </div>

        {/* What the AI sees: boxes, labels, and the shots being fired. */}
        <canvas ref={aiRef} aria-hidden="true" className="pointer-events-none absolute inset-0 size-full" />

        {ORDER.slice(3).map((n) => layer(n))}

        {/* "Signal lost": static on the camera feed. */}
        <div ref={veilRef} aria-hidden="true" className="pointer-events-none absolute inset-0 bg-void">
          <canvas ref={staticRef} width={160} height={100} className="absolute inset-0 size-full opacity-25 [image-rendering:pixelated]" />
          <div className="scanlines absolute inset-0" />
          <div className="absolute inset-0 bg-[radial-gradient(80%_80%_at_50%_50%,transparent,rgba(7,11,20,0.9))]" />
          <div className="absolute inset-x-0 top-1/2 -translate-y-1/2 px-4 text-center">
            <p className="font-mono text-label text-alert uppercase">
              <span className="mr-2 inline-block size-2 rounded-full bg-alert align-middle motion-safe:animate-[rec-blink_1s_steps(1)_infinite]" />
              {hero.veilTop}
            </p>
            <p className="mt-3 font-display text-[0.8125rem] tracking-[0.5em] text-white/90 uppercase" style={{marginRight: '-0.5em'}}>
              {hero.veilCta}
            </p>
            <span aria-hidden="true" className="mt-6 inline-block animate-bounce text-steel/70 motion-reduce:animate-none">
              ↓
            </span>
          </div>
        </div>

        {/* Camera HUD. */}
        <div ref={hudRef} aria-hidden="true" className="pointer-events-none absolute inset-4 font-mono text-[0.625rem] tracking-[0.14em] text-steel/80 uppercase sm:inset-6 md:text-label" style={{opacity: 0}}>
          <div className="brackets absolute inset-0 text-steel/40" />
          <div className="absolute top-16 left-3 space-y-1 md:top-20 md:left-4">
            <p className="flex items-center gap-2 text-white">
              <span className="inline-block size-2 rounded-full bg-alert motion-safe:animate-[rec-blink_1s_steps(1)_infinite]" />
              Rec <span ref={clockRef} className="tabular-nums">05:41:30</span>
            </p>
            <p className="text-steel/50 max-sm:hidden">Witness phone · live</p>
          </div>
          <div className="absolute top-16 right-3 space-y-1 text-right md:top-20 md:right-4">
            <p className="text-steel/50">Argus AI</p>
            <p ref={countRef} className="text-signal">
              Scanning…
            </p>
            <p ref={alertRef} className="text-alert" style={{opacity: 0}}>
              Shots detected
            </p>
          </div>
          <div className="absolute bottom-3 left-3 md:bottom-4 md:left-4">{hero.site}</div>
          <div className="absolute right-3 bottom-3 flex items-center gap-2 md:right-4 md:bottom-4">
            Scroll <span className="inline-block animate-bounce motion-reduce:animate-none">↓</span>
          </div>
        </div>
      </div>
    </section>
  );
}
