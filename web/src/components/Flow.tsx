import {useEffect, useRef} from 'react';
import {flow, users} from '../content';
import {useFrame} from '../hooks/useFrame';
import {ease, pinProgress, range} from '../lib/scroll';

/**
 * The flow is drawn, not animated on a timer. The section pins for
 * SECTION_VH and draws the four legs in order inside WINDOW. The dots and
 * the readouts are functions of the same progress.
 */
const SECTION_VH = 380;
const WINDOW: [number, number] = [0.08, 0.86];

const X = [110, 300, 490];
const SHARED = 'var(--color-shared)';

/** One leg: the paths that draw at the same time, and their colours. */
const LEGS: {d: string; color: string}[][] = [
  [{d: 'M300 74V146', color: SHARED}],
  X.map((x, i) => ({d: `M300 194C300 250 ${x} 240 ${x} 296`, color: users[i].color})),
  X.map((x, i) => ({d: `M${x} 344V414`, color: users[i].color})),
  X.map((x, i) => {
    const end = 300 + (x - 300) * 0.32;
    return {d: `M${x} 462C${x} 520 ${end} 500 ${end} 554`, color: users[i].color};
  }),
];

type Node = {x: number; y: number; w: number; label: string; sub?: string; color: string; leg: number};
const NODES: Node[] = [
  {x: 300, y: 50, w: 210, label: 'Shared stack', sub: 'reviewed in Git', color: SHARED, leg: -1},
  {x: 300, y: 170, w: 210, label: 'team-host', sub: 'one AI harness', color: SHARED, leg: 0},
  ...X.map((x, i) => ({x, y: 320, w: 160, label: users[i].name, sub: 'Unix account', color: users[i].color, leg: 1})),
  ...X.map((x, i) => ({x, y: 438, w: 160, label: 'runtime', sub: `as ${users[i].name}`, color: users[i].color, leg: 2})),
  {x: 300, y: 580, w: 330, label: 'Git · GitHub · Azure · gateway', sub: 'each record shows its user', color: '#e8ebf5', leg: 3},
];

export function Flow({reduced}: {reduced: boolean}) {
  const section = useRef<HTMLElement>(null);
  const paths = useRef<(SVGPathElement | null)[][]>(LEGS.map(() => []));
  const dots = useRef<(SVGCircleElement | null)[][]>(LEGS.map(() => []));
  const nodes = useRef<(SVGGElement | null)[]>([]);
  const steps = useRef<(HTMLLIElement | null)[]>([]);
  const stepOut = useRef<HTMLSpanElement>(null);
  const keyOut = useRef<HTMLSpanElement>(null);
  const lengths = useRef<number[][]>([]);
  const active = useRef(-1);

  useEffect(() => {
    lengths.current = paths.current.map((leg) => leg.map((p) => p?.getTotalLength() ?? 0));
  }, []);

  useFrame((y, vh) => {
    if (!section.current) return;
    const p = reduced ? 1 : pinProgress(section.current, y, vh);
    const w = range(p, WINDOW[0], WINDOW[1]) * LEGS.length;

    const legT = LEGS.map((_, i) => ease(Math.min(1, Math.max(0, w - i))));
    legT.forEach((t, i) => {
      paths.current[i].forEach((path, j) => {
        if (!path) return;
        path.style.strokeDashoffset = String(1 - t);
        const dot = dots.current[i][j];
        const len = lengths.current[i]?.[j];
        if (!dot || !len) return;
        const on = t > 0 && t < 1;
        dot.style.opacity = on ? '1' : '0';
        if (on) {
          const pt = path.getPointAtLength(len * t);
          dot.setAttribute('cx', String(pt.x));
          dot.setAttribute('cy', String(pt.y));
        }
      });
    });

    NODES.forEach((n, i) => {
      const g = nodes.current[i];
      if (!g) return;
      const t = n.leg < 0 ? 1 : range(legT[n.leg], 0.75, 1);
      g.style.opacity = String(0.12 + 0.88 * t);
      // A node glows for a moment when its leg reaches it.
      const glow = n.leg < 0 ? 0 : range(legT[n.leg], 0.9, 1) * (1 - range(w, n.leg + 1.2, n.leg + 1.8));
      g.style.filter = glow > 0.01 ? `drop-shadow(0 0 ${12 * glow}px ${n.color})` : '';
    });

    const now = Math.min(LEGS.length - 1, Math.floor(w));
    if (now !== active.current) {
      active.current = now;
      steps.current.forEach((li, i) => {
        if (!li) return;
        li.dataset.state = reduced ? 'on' : i === now ? 'on' : i < now ? 'done' : 'off';
      });
      if (stepOut.current) stepOut.current.textContent = `${String(now + 1).padStart(2, '0')}/${String(LEGS.length).padStart(2, '0')}`;
    }
    if (keyOut.current) keyOut.current.textContent = `${Math.round(legT[1] * users.length)}/${users.length}`;
  });

  return (
    <section id="how" ref={section} style={{height: reduced ? 'auto' : `${SECTION_VH}vh`}} className="relative bg-night">
      <div className={reduced ? 'py-24' : 'sticky top-0 h-screen-s overflow-hidden'}>
        <div className="mx-auto grid h-full max-w-7xl grid-rows-[auto_minmax(0,1fr)_auto] gap-4 px-4 pt-20 pb-6 sm:px-6 md:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)] md:grid-rows-1 md:items-center md:gap-12 md:px-[3vw] md:pt-16">
          <div className="md:self-center">
            <p className="font-mono text-label text-alice uppercase">{flow.eyebrow}</p>
            <h2 className="mt-4 font-display text-[clamp(1.5rem,2.8vw,2.5rem)] leading-[1.12] text-white">{flow.heading}</h2>
            <ol className="mt-6 hidden space-y-5 md:block">
              {flow.steps.map((s, i) => (
                <li
                  key={s.n}
                  ref={(el) => {
                    steps.current[i] = el;
                  }}
                  data-state="off"
                  className="grid grid-cols-[2.5rem_1fr] transition-opacity duration-500 data-[state=done]:opacity-45 data-[state=off]:opacity-25"
                >
                  <span className="font-mono text-label text-faint">{s.n}</span>
                  <div>
                    <h3 className="text-lead font-semibold text-white">{s.title}</h3>
                    <p className="mt-1 text-body text-muted">{s.body}</p>
                  </div>
                </li>
              ))}
            </ol>
          </div>

          <svg viewBox="0 0 600 630" className="mx-auto h-full max-h-[72svh] w-full max-w-[600px]" role="img" aria-label="The shared stack goes from Git to the host. The host enrolls alice, bob and carol, each with a Unix account. The runtime of each user runs in that account. Git, GitHub, Azure and the model gateway record each action as its user.">
            {LEGS.map((leg, i) =>
              leg.map((l, j) => (
                <g key={`${i}-${j}`}>
                  <path d={l.d} fill="none" stroke="rgba(255,255,255,.08)" strokeWidth="1.5" strokeDasharray="3 5" />
                  <path
                    ref={(el) => {
                      paths.current[i][j] = el;
                    }}
                    d={l.d}
                    pathLength={1}
                    fill="none"
                    stroke={l.color}
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeDasharray="1"
                    strokeDashoffset="1"
                  />
                  <circle
                    ref={(el) => {
                      dots.current[i][j] = el;
                    }}
                    r="5"
                    fill={l.color}
                    opacity="0"
                    style={{filter: `drop-shadow(0 0 6px ${l.color})`}}
                  />
                </g>
              )),
            )}
            {NODES.map((n, i) => (
              <g
                key={`${n.label}-${i}`}
                ref={(el) => {
                  nodes.current[i] = el;
                }}
                opacity={n.leg < 0 ? 1 : 0.12}
              >
                <rect x={n.x - n.w / 2} y={n.y - 24} width={n.w} height="48" rx="8" fill="#11172d" stroke={n.color} strokeOpacity="0.55" />
                <text x={n.x} y={n.y - 3} textAnchor="middle" fill={n.color} fontFamily="var(--font-mono)" fontSize="14" letterSpacing="1">
                  {n.label}
                </text>
                {n.sub ? (
                  <text x={n.x} y={n.y + 14} textAnchor="middle" fill="#7d86a8" fontFamily="var(--font-mono)" fontSize="10.5" letterSpacing="0.5">
                    {n.sub}
                  </text>
                ) : null}
              </g>
            ))}
          </svg>

          {/* Small screens: only the active step, under the drawing. */}
          <div className="md:hidden">
            {flow.steps.map((s, i) => (
              <StepSmall key={s.n} s={s} i={i} reduced={reduced} />
            ))}
          </div>
        </div>

        <div className="pointer-events-none absolute right-4 bottom-5 hidden space-y-1 text-right font-mono text-label text-white/70 uppercase sm:right-6 md:block md:right-[3vw]">
          <div>
            Step <span ref={stepOut} className="tabular-nums text-white">01/04</span>
          </div>
          <div>
            Gateway keys <span ref={keyOut} className="tabular-nums text-alice">0/3</span>
          </div>
          <div>
            {flow.readout} <span className="text-ok">0</span>
          </div>
        </div>
      </div>
    </section>
  );
}

/** On small screens the steps stack in one cell; only the active one shows. */
function StepSmall({s, i, reduced}: {s: (typeof flow.steps)[number]; i: number; reduced: boolean}) {
  const ref = useRef<HTMLDivElement>(null);
  const section = useRef<HTMLElement | null>(null);
  useEffect(() => {
    section.current = document.getElementById('how');
  }, []);
  useFrame((y, vh) => {
    if (!ref.current || !section.current) return;
    if (reduced) {
      ref.current.style.display = 'block';
      return;
    }
    const w = range(pinProgress(section.current, y, vh), WINDOW[0], WINDOW[1]) * LEGS.length;
    const on = Math.min(LEGS.length - 1, Math.floor(w)) === i;
    const want = on ? 'block' : 'none';
    if (ref.current.style.display !== want) ref.current.style.display = want;
  });
  return (
    <div ref={ref} style={{display: i === 0 || reduced ? 'block' : 'none', animation: 'step-in .6s cubic-bezier(.2,.7,.1,1)'}} className={reduced ? 'mb-5' : ''}>
      <p className="font-mono text-label text-faint">
        {s.n} / 04
      </p>
      <h3 className="mt-1 text-lead font-semibold text-white">{s.title}</h3>
      <p className="mt-1 text-body text-muted">{s.body}</p>
    </div>
  );
}
