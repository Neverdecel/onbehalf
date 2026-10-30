import {useEffect, useMemo, useRef} from 'react';
import {hero, users} from '../content';
import {useFrame} from '../hooks/useFrame';
import {ease, pinProgress, range} from '../lib/scroll';

/**
 * The hero is a pinned stage of layers. Each layer moves at its own rate
 * with the scroll. There is no video and no WebGL: depth comes from the
 * layers that slide past each other.
 *
 * Beats, as fractions of the pinned scroll:
 *   0.00–0.22  the fog clears
 *   0.24–0.70  the host rises from behind the ground (the fog is gone first)
 *   0.40–0.62  the title comes in
 *   0.72–1.00  one identity line for each user, from the host to that user
 * All motion stops at 0.70, so that the lines join points that do not move.
 */
const HERO_VH = 320;
const RISE: [number, number] = [0.24, 0.7];
const LINE_START = 0.72;
const LINE_STEP = 0.07;
const LINE_LEN = 0.12;

/** Stage coordinates (viewBox 1200 × 900). */
const CORE = {x: 600, y: 520};
const PEOPLE = [
  {x: 300, y: 742},
  {x: 430, y: 760},
  {x: 900, y: 748},
];
const PEOPLE_DROP = 60;
const GROUND_DROP = 35;
const HOST_DROP = 470;
/** Pointer parallax, in stage units at the edge of the screen. Near layers move more. */
const TILT = {ridge: 6, host: 12, people: 26, sky: 10};
/** Seconds for one pulse to go from the host to a user. */
const PULSE_S = 2.6;

/** A small seeded PRNG, so the stars are the same on each load. */
function stars(n: number) {
  let s = 7;
  const r = () => ((s = (s * 16807) % 2147483647) / 2147483647);
  return Array.from({length: n}, () => ({x: r() * 1600, y: r() * 700, r: r() < 0.9 ? 0.6 + r() * 0.8 : 1.4 + r(), o: 0.25 + r() * 0.6}));
}

function Person({name, color}: {name: string; color: string}) {
  return (
    <g>
      <ellipse cx="0" cy="4" rx="34" ry="7" fill="#04060e" />
      <circle cx="0" cy="-62" r="9" fill="#04060e" />
      <path d="M-14 -50Q0 -56 14 -50L17 -20 11 -20 10 0 3 0 1 -20-1 -20-3 0-10 0-11-20-17-20Z" fill="#04060e" />
      <circle data-badge cx="0" cy="-38" r="9" fill={color} opacity="0" style={{filter: 'blur(4px)'}} />
      <circle cx="0" cy="-38" r="3" fill={color} />
      <text x="0" y="28" textAnchor="middle" fill={color} fontFamily="var(--font-mono)" fontSize="15" letterSpacing="1.5">
        {name}
      </text>
    </g>
  );
}

function Host() {
  const slits = Array.from({length: 13}, (_, i) => 368 + i * 26);
  return (
    <g>
      <defs>
        <linearGradient id="host-body" x1="0" y1="0" x2="1" y2="0">
          <stop offset="0" stopColor="#1d2550" />
          <stop offset="0.5" stopColor="#141a3a" />
          <stop offset="1" stopColor="#0c1128" />
        </linearGradient>
        <radialGradient id="host-core">
          <stop offset="0" stopColor="#ffffff" />
          <stop offset="0.25" stopColor="#c9c0ff" />
          <stop offset="1" stopColor="#a596ff" stopOpacity="0" />
        </radialGradient>
      </defs>
      <path d="M530 360Q530 330 560 330H640Q670 330 670 360V800H530Z" fill="url(#host-body)" stroke="rgba(165,150,255,.4)" strokeWidth="1.2" />
      {slits.map((y, i) => (
        <rect key={y} x="552" y={y} width="96" height="3" rx="1.5" fill="#a596ff" opacity={i === 6 ? 0 : 0.18 + ((i * 37) % 5) * 0.08} />
      ))}
      <circle cx={CORE.x} cy={CORE.y} r="46" fill="url(#host-core)" />
      <circle cx={CORE.x} cy={CORE.y} r="6" fill="#fff" />
      <circle cx="600" cy="330" r="3" fill="#2dd4bf" style={{animation: 'blink 2.4s steps(1) infinite'}} />
    </g>
  );
}

export function Hero({reduced}: {reduced: boolean}) {
  const section = useRef<HTMLElement>(null);
  const veil = useRef<HTMLDivElement>(null);
  const hint = useRef<HTMLParagraphElement>(null);
  const glow = useRef<SVGGElement>(null);
  const ridge = useRef<SVGGElement>(null);
  const host = useRef<SVGGElement>(null);
  const ground = useRef<SVGGElement>(null);
  const people = useRef<SVGGElement>(null);
  const lines = useRef<(SVGPathElement | null)[]>([]);
  const title = useRef<HTMLHeadingElement>(null);
  const kicker = useRef<HTMLParagraphElement>(null);
  const stackOut = useRef<HTMLSpanElement>(null);
  const idOut = useRef<HTMLSpanElement>(null);
  const clock = useRef<HTMLSpanElement>(null);
  const linesG = useRef<SVGGElement>(null);
  const pulses = useRef<(SVGCircleElement | null)[]>([]);
  const lengths = useRef<number[]>([]);
  const sky = useRef<SVGSVGElement>(null);
  /** Pointer position (-1..1), and the eased value that the layers follow. */
  const pointer = useRef({x: 0, y: 0, ex: 0, ey: 0});
  const field = useMemo(() => stars(170), []);

  useEffect(() => {
    lengths.current = lines.current.map((l) => l?.getTotalLength() ?? 0);
    // Only a mouse or a pen moves the scene; a touch screen scrolls.
    if (reduced || !window.matchMedia('(pointer: fine)').matches) return;
    const move = (e: PointerEvent) => {
      pointer.current.x = (e.clientX / window.innerWidth) * 2 - 1;
      pointer.current.y = (e.clientY / window.innerHeight) * 2 - 1;
    };
    window.addEventListener('pointermove', move, {passive: true});
    return () => window.removeEventListener('pointermove', move);
  }, [reduced]);

  // The clock writes the text directly, one time each second.
  useEffect(() => {
    const tick = () => {
      if (clock.current) clock.current.textContent = new Date().toISOString().slice(11, 19);
    };
    tick();
    const id = window.setInterval(tick, 1000);
    return () => window.clearInterval(id);
  }, []);

  useFrame((y, vh) => {
    if (!section.current) return;
    const p = reduced ? 1 : pinProgress(section.current, y, vh);

    const v = ease(range(p, 0, 0.22));
    if (veil.current) {
      veil.current.style.opacity = String(1 - v);
      veil.current.style.transform = `scale(${1 + v * 0.35})`;
      veil.current.style.visibility = v >= 1 ? 'hidden' : 'visible';
    }
    if (hint.current) hint.current.style.opacity = String(1 - range(p, 0, 0.06));

    const settle = ease(range(p, 0, RISE[1]));
    const r = ease(range(p, RISE[0], RISE[1]));
    const m = pointer.current;
    m.ex += (m.x - m.ex) * 0.06;
    m.ey += (m.y - m.ey) * 0.06;
    const tx = (k: number) => -m.ex * k;
    const ty = (k: number) => -m.ey * k * 0.5;
    sky.current?.style.setProperty('transform', `translate3d(${tx(TILT.sky)}px, ${ty(TILT.sky)}px, 0) scale(1.03)`);
    ridge.current?.style.setProperty('transform', `translate3d(${tx(TILT.ridge)}px, ${settle * 18 + ty(TILT.ridge)}px, 0)`);
    glow.current?.style.setProperty('opacity', String(r * (0.85 + 0.15 * Math.sin(performance.now() / 700))));
    host.current?.style.setProperty('transform', `translate3d(${tx(TILT.host)}px, ${(1 - r) * HOST_DROP + settle * 6 + ty(TILT.host)}px, 0)`);
    ground.current?.style.setProperty('transform', `translate3d(${tx(TILT.host)}px, ${settle * GROUND_DROP + ty(TILT.host)}px, 0)`);
    people.current?.style.setProperty('transform', `translate3d(${tx(TILT.people)}px, ${settle * PEOPLE_DROP + ty(TILT.people)}px, 0)`);

    // The lines join the host and the people, so they follow the mean of the two tilts.
    const mid = (TILT.host + TILT.people) / 2;
    linesG.current?.style.setProperty('transform', `translate3d(${tx(mid)}px, ${ty(mid)}px, 0)`);

    let done = 0;
    lines.current.forEach((path, i) => {
      if (!path) return;
      const d = ease(range(p, LINE_START + i * LINE_STEP, LINE_START + i * LINE_STEP + LINE_LEN));
      path.style.strokeDashoffset = String(1 - d);
      const badge = people.current?.querySelectorAll<SVGCircleElement>('[data-badge]')[i];
      badge?.setAttribute('opacity', String(d));
      if (d >= 1) done++;
      // When a line is complete, light pulses go from the host to its user.
      const pulse = pulses.current[i];
      const len = lengths.current[i];
      if (!pulse || !len) return;
      if (d < 1 || reduced) {
        pulse.style.opacity = '0';
        return;
      }
      const t = ((performance.now() / 1000 / PULSE_S + i * 0.33) % 1 + 1) % 1;
      const pt = path.getPointAtLength(len * t);
      pulse.setAttribute('cx', String(pt.x));
      pulse.setAttribute('cy', String(pt.y));
      pulse.style.opacity = String(Math.sin(t * Math.PI));
    });

    const t = ease(range(p, 0.4, 0.62));
    if (title.current) {
      title.current.style.opacity = String(t);
      title.current.style.letterSpacing = `${0.4 - 0.16 * t}em`;
      title.current.style.transform = `translate3d(0, ${(1 - t) * 24}px, 0)`;
    }
    kicker.current?.style.setProperty('opacity', String(range(p, 0.55, 0.72)));
    if (stackOut.current) stackOut.current.textContent = `${String(Math.round(r * 100)).padStart(3, ' ')}%`;
    if (idOut.current) idOut.current.textContent = `${done}/${users.length}`;
  });

  return (
    <section id="top" ref={section} aria-label="onbehalf" style={{height: reduced ? '100svh' : `${HERO_VH}vh`}} className="relative">
      <div className="sticky top-0 h-screen-s overflow-hidden">
        {/* Sky */}
        <div aria-hidden="true" className="absolute inset-0" style={{background: 'radial-gradient(120% 80% at 50% 85%, #1c2152 0%, #0f1533 45%, #0b1022 75%)'}} />
        <svg ref={sky} aria-hidden="true" className="absolute inset-0 size-full" viewBox="0 0 1600 900" preserveAspectRatio="xMidYMax slice">
          {field.map((s, i) => (
            <circle
              key={i}
              cx={s.x}
              cy={s.y}
              r={s.r}
              fill="#e8ebf5"
              opacity={s.o}
              // One star in five twinkles, each on its own beat.
              style={i % 5 === 0 ? {animation: `twinkle ${3 + (i % 7)}s ease-in-out ${(i % 11) * 0.4}s infinite`} : undefined}
            />
          ))}
        </svg>

        {/* The scene: ridge, host, ground, people and identity lines share one box. */}
        <div aria-hidden="true" className="absolute bottom-0 left-1/2 aspect-[4/3] w-[min(100vw,125svh)] -translate-x-1/2 portrait:bottom-16 portrait:w-[160vw]">
          <svg className="absolute inset-0 size-full overflow-visible" viewBox="0 0 1200 900">
            <defs>
              <radialGradient id="host-glow">
                <stop offset="0" stopColor="#a596ff" stopOpacity="0.45" />
                <stop offset="1" stopColor="#a596ff" stopOpacity="0" />
              </radialGradient>
            </defs>
            <g ref={glow} opacity="0">
              <ellipse cx={CORE.x} cy={CORE.y} rx="420" ry="320" fill="url(#host-glow)" />
            </g>
            <g ref={ridge}>
              <path d="M-1400 640 -900 600-600 628-300 590 0 612 220 584 420 606 600 596 780 610 1000 582 1240 612 1500 594 1900 626 2600 600V1400H-1400Z" fill="#121935" />
              <path d="M-1400 668-1000 650-700 672-420 648-160 666 120 652 380 674 620 660 880 676 1100 656 1380 670 1700 652 2600 668V1400H-1400Z" fill="#0d1329" />
            </g>
            <g ref={host}>
              <Host />
            </g>
            <g ref={ground}>
              <path
                d="M-2000 720 -600 712 0 716 180 714 260 730 340 734 400 744 470 748 560 722 680 718 820 724 860 738 940 742 1000 726 1200 716 1800 722 3200 716V1600H-2000Z"
                fill="#060914"
                stroke="rgba(165,173,203,.16)"
                strokeWidth="1.2"
              />
            </g>
            <g ref={linesG}>
            {users.map((u, i) => {
              const a = PEOPLE[i];
              const by = a.y + PEOPLE_DROP - 38;
              const midY = (CORE.y + by) / 2;
              return (
                <path
                  key={u.name}
                  ref={(el) => {
                    lines.current[i] = el;
                  }}
                  d={`M${CORE.x} ${CORE.y}C${CORE.x} ${midY + 40} ${a.x} ${midY - 30} ${a.x} ${by}`}
                  pathLength={1}
                  fill="none"
                  stroke={u.color}
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeDasharray="1"
                  strokeDashoffset="1"
                  style={{filter: `drop-shadow(0 0 6px ${u.color})`}}
                />
              );
            })}
            {users.map((u, i) => (
              <circle
                key={u.name}
                ref={(el) => {
                  pulses.current[i] = el;
                }}
                r="4"
                fill="#fff"
                opacity="0"
                style={{filter: `drop-shadow(0 0 8px ${u.color}) drop-shadow(0 0 3px ${u.color})`}}
              />
            ))}
            </g>
            <g ref={people}>
              {users.map((u, i) => (
                <g key={u.name} transform={`translate(${PEOPLE[i].x} ${PEOPLE[i].y}) scale(1.25)`}>
                  <Person name={u.name} color={u.color} />
                </g>
              ))}
            </g>
          </svg>
        </div>

        {/* Title */}
        <div className="pointer-events-none absolute inset-x-0 top-[17svh] px-4 text-center sm:top-[15svh]">
          <h1 ref={title} className="font-display text-hero whitespace-nowrap text-white opacity-0" style={{paddingLeft: '0.24em'}}>
            {hero.title}
          </h1>
          <p ref={kicker} className="mt-5 text-lead text-muted opacity-0">
            {hero.kicker}
          </p>
        </div>

        {/* Readouts */}
        <div className="pointer-events-none absolute inset-x-0 bottom-0 flex items-end justify-between px-4 pb-5 font-mono text-label text-white/70 uppercase sm:px-6 md:px-[3vw]">
          <div className="space-y-1">
            <div className="hidden sm:block">{hero.host}</div>
            <div className="sm:hidden">{hero.host.split(' · ')[0]}</div>
            <div>
              UTC <span ref={clock} className="tabular-nums" />
            </div>
          </div>
          <div className="space-y-1 text-right">
            <div>
              Shared stack <span ref={stackOut} className="tabular-nums text-shared" />
            </div>
            <div>
              Identities <span ref={idOut} className="tabular-nums text-alice" />
            </div>
          </div>
        </div>

        {/* The fog. It covers the scene until the first beat clears it. */}
        <div
          ref={veil}
          aria-hidden="true"
          className="absolute inset-0 flex items-center justify-center"
          style={{
            display: reduced ? 'none' : undefined,
            background:
              'radial-gradient(60% 50% at 30% 40%, rgba(165,150,255,.22), transparent 70%), radial-gradient(50% 45% at 72% 62%, rgba(45,212,191,.14), transparent 70%), radial-gradient(80% 60% at 50% 50%, #151b3b, #0b1022)',
          }}
        >
          <p ref={hint} className="flex flex-col items-center gap-4 font-mono text-label text-white/70 uppercase">
            {hero.hint}
            <span className="block h-10 w-px bg-gradient-to-b from-white/70 to-transparent" />
          </p>
        </div>
      </div>
    </section>
  );
}
