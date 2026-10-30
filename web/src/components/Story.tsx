import {useRef, type ReactNode} from 'react';
import {story, users} from '../content';
import {useFrame} from '../hooks/useFrame';
import {clamp, pinProgress, range} from '../lib/scroll';

/**
 * The scroll story. The section pins, and one stage shows the three ways to
 * share a setup, one after the other: laptops, one shared account,
 * onbehalf. The score of five points changes with the stage.
 */
const SECTION_VH = 360;
const WINDOW: [number, number] = [0.04, 0.94];
/** Half of the cross-fade between two beats, in beats. */
const FADE = 0.12;

const color = (name: string) => users.find((u) => u.name === name)?.color;
const COMMITS = [
  {hash: 'a1f3c09', msg: 'Fix the login timeout'},
  {hash: '9c2e7b4', msg: 'Add a rate limit'},
  {hash: '47bd1e2', msg: 'Update the API docs'},
];

function Label({children}: {children: ReactNode}) {
  return <p className="mb-2 font-mono text-[0.625rem] tracking-[0.16em] text-faint uppercase">{children}</p>;
}

function Card({children, className = '', style}: {children: ReactNode; className?: string; style?: React.CSSProperties}) {
  return (
    <div className={`min-w-0 rounded-md border px-3 py-2.5 ${className}`} style={style}>
      {children}
    </div>
  );
}

/** The setup row: different for each beat. */
function Setup({beat}: {beat: number}) {
  if (beat === 0) {
    const setups = ['AGENTS.md v4 · 6 skills', 'AGENTS.md v1 · 2 skills', 'no setup'];
    return (
      <div className="grid grid-cols-3 gap-2">
        {users.map((u, i) => (
          <Card key={u.name} className="border-line bg-night">
            <p className="font-mono text-[0.75rem]" style={{color: u.color}}>
              {u.name}’s laptop
            </p>
            <p className={`mt-1 font-mono text-[0.6875rem] ${i === 0 ? 'text-muted' : 'text-bob'}`}>{setups[i]}</p>
          </Card>
        ))}
      </div>
    );
  }
  if (beat === 1) {
    return (
      <Card className="border-bad/40 bg-bad/5">
        <div className="flex items-center justify-between gap-3">
          <p className="font-mono text-[0.75rem] text-ink">team-bot · one shared account</p>
          <span className="flex -space-x-1.5" aria-hidden="true">
            {users.map((u) => (
              <span key={u.name} className="flex size-5 items-center justify-center rounded-full border border-night text-[0.625rem] text-night" style={{background: u.color}}>
                {u.name[0].toUpperCase()}
              </span>
            ))}
          </span>
        </div>
        <p className="mt-1 font-mono text-[0.6875rem] text-muted">AGENTS.md v4 · 6 skills · one set of logins</p>
      </Card>
    );
  }
  return (
    <div className="space-y-2">
      <Card className="border-shared/40 bg-shared/10">
        <p className="font-mono text-[0.75rem] text-shared">◆ shared stack 3f9c2a1b7e04 · reviewed in Git · read-only</p>
      </Card>
      <div className="grid grid-cols-3 gap-2">
        {users.map((u, i) => (
          <Card key={u.name} className="bg-night" style={{borderColor: `color-mix(in srgb, ${u.color} 45%, transparent)`}}>
            <p className="font-mono text-[0.75rem]" style={{color: u.color}}>
              {u.name} · uid {1001 + i}
            </p>
            <p className="mt-1 font-mono text-[0.6875rem] text-muted">
              <span className="text-ok">✓</span> stack 3f9c2a1
            </p>
          </Card>
        ))}
      </div>
    </div>
  );
}

function Panel({beat}: {beat: number}) {
  const shared = beat === 1;
  const creds = [
    {out: 'No such file (a different laptop)', tone: 'text-faint', mark: '·'},
    {out: 'oauth_token: gho_••••••••••••', tone: 'text-bad', mark: '✗'},
    {out: 'Permission denied', tone: 'text-ok', mark: '✓'},
  ][beat];
  const cost = [
    <span className="text-bob">unknown: each user pays on a personal account</span>,
    <span className="text-bad">one total for team-bot</span>,
    <>
      {users.map((u, i) => (
        <span key={u.name}>
          <span style={{color: u.color}}>{u.name}</span> {['1.9M', '1.1M', '0.4M'][i]}
          {i < users.length - 1 ? ' · ' : ''}
        </span>
      ))}{' '}
      <span className="text-faint">tokens</span>
    </>,
  ][beat];
  return (
    <div className="space-y-5">
      <div>
        <Label>The setup</Label>
        <Setup beat={beat} />
      </div>
      <div>
        <Label>git log --format='%h %an %s'</Label>
        <div className="rounded-md border border-line bg-night px-3 py-2 font-mono text-[0.75rem] leading-[1.8]">
          {COMMITS.map((c, i) => {
            const user = users[i].name;
            return (
              <div key={c.hash} className="flex min-w-0 gap-3 whitespace-nowrap">
                <span className="text-faint">{c.hash}</span>
                <span className="w-[4.5rem] shrink-0" style={{color: shared ? 'var(--color-bad)' : color(user)}}>
                  {shared ? 'team-bot' : user}
                </span>
                <span className="truncate text-muted">{c.msg}</span>
              </div>
            );
          })}
        </div>
      </div>
      <div>
        <Label>bob reads the GitHub login of alice</Label>
        <div className="rounded-md border border-line bg-night px-3 py-2 font-mono text-[0.75rem] leading-[1.8]">
          <div className="truncate text-ink">
            <span style={{color: color('bob')}}>bob</span>
            <span className="text-faint">$ </span>cat ~alice/.config/gh/hosts.yml
          </div>
          <div className={creds.tone}>
            {creds.mark} {creds.out}
          </div>
        </div>
      </div>
      <div>
        <Label>Model use</Label>
        <p className="font-mono text-[0.75rem]">{cost}</p>
      </div>
    </div>
  );
}

function Score({beat}: {beat?: number}) {
  const has = beat === undefined ? null : story.has[beat];
  return (
    <ul className="space-y-2">
      {story.points.map((pt, i) => (
        <li key={pt} data-point className="grid grid-cols-[1.25rem_1fr] gap-2 text-[0.875rem] leading-snug">
          <span data-mark aria-hidden="true" className={has ? (has[i] ? 'text-ok' : 'text-bad') : 'text-faint'}>
            {has ? (has[i] ? '✓' : '✗') : '·'}
          </span>
          <span data-text className={has && !has[i] ? 'text-faint' : 'text-ink'}>
            {has ? <span className="sr-only">{has[i] ? 'Yes: ' : 'No: '}</span> : null}
            {pt}
          </span>
        </li>
      ))}
    </ul>
  );
}

export function Story({reduced}: {reduced: boolean}) {
  const section = useRef<HTMLElement>(null);
  const panels = useRef<(HTMLDivElement | null)[]>([]);
  const texts = useRef<(HTMLDivElement | null)[]>([]);
  const bars = useRef<(HTMLSpanElement | null)[]>([]);
  const score = useRef<HTMLDivElement>(null);
  const count = useRef<HTMLSpanElement>(null);
  const shown = useRef(-1);

  useFrame((y, vh) => {
    if (reduced || !section.current) return;
    const p = pinProgress(section.current, y, vh);
    const n = story.beats.length;
    const f = range(p, WINDOW[0], WINDOW[1]) * n;

    for (let i = 0; i < n; i++) {
      // Fully visible inside its beat; a short cross-fade at each border.
      const lo = i === 0 ? -1 : i;
      const hi = i === n - 1 ? n + 1 : i + 1;
      const o = Math.min(clamp((f - lo + FADE) / (2 * FADE)), clamp((hi - f + FADE) / (2 * FADE)));
      const panel = panels.current[i];
      if (panel) {
        panel.style.opacity = String(o);
        panel.style.transform = `translate3d(0, ${(1 - o) * (f < i + 0.5 ? 14 : -14)}px, 0)`;
        panel.style.visibility = o <= 0.001 ? 'hidden' : 'visible';
      }
      const text = texts.current[i];
      if (text) {
        text.style.opacity = String(o);
        text.style.visibility = o <= 0.001 ? 'hidden' : 'visible';
      }
      bars.current[i]?.style.setProperty('transform', `scaleX(${clamp(f - i)})`);
    }

    const beat = Math.min(n - 1, Math.floor(f));
    if (beat === shown.current || !score.current) return;
    shown.current = beat;
    const has = story.has[beat];
    score.current.querySelectorAll('[data-point]').forEach((li, i) => {
      const mark = li.querySelector<HTMLElement>('[data-mark]');
      const text = li.querySelector<HTMLElement>('[data-text]');
      if (mark) {
        mark.textContent = has[i] ? '✓' : '✗';
        mark.className = has[i] ? 'text-ok' : 'text-bad';
        mark.style.animation = 'none';
        void mark.offsetWidth;
        mark.style.animation = 'step-in .45s cubic-bezier(.2,.7,.1,1)';
      }
      if (text) text.className = has[i] ? 'text-ink' : 'text-faint';
    });
    if (count.current) count.current.textContent = `${has.filter(Boolean).length} of ${has.length}`;
  });

  const head = (
    <div>
      <p className="font-mono text-label text-alice uppercase">{story.eyebrow}</p>
      <h2 className="mt-4 font-display text-[clamp(1.5rem,2.8vw,2.5rem)] leading-[1.12] text-white">{story.heading}</h2>
    </div>
  );

  if (reduced) {
    return (
      <section id="problem" className="px-4 py-24 sm:px-6 md:px-[3vw]">
        <div className="mx-auto max-w-7xl">
          {head}
          <div className="mt-12 space-y-16">
            {story.beats.map((b, i) => (
              <div key={b.tag} className="grid gap-8 lg:grid-cols-[minmax(0,0.8fr)_minmax(0,1.2fr)]">
                <div>
                  <p className="font-mono text-label text-faint uppercase">{b.tag}</p>
                  <h3 className="mt-2 text-lead font-semibold text-white">{b.title}</h3>
                  <p className="mt-2 text-body text-muted">{b.body}</p>
                  <div className="mt-6">
                    <Score beat={i} />
                  </div>
                </div>
                <div className="rounded-xl border border-line bg-night-2 p-5">
                  <Panel beat={i} />
                </div>
              </div>
            ))}
          </div>
        </div>
      </section>
    );
  }

  return (
    <section id="problem" ref={section} style={{height: `${SECTION_VH}vh`}} className="relative">
      <div className="sticky top-0 h-screen-s overflow-hidden">
        <div className="mx-auto grid h-full max-w-7xl grid-cols-[minmax(0,1fr)] content-center gap-5 px-4 pt-16 pb-4 sm:px-6 md:px-[3vw] lg:grid-cols-[minmax(0,0.85fr)_minmax(0,1.15fr)] lg:gap-14">
          <div className="min-w-0">
            {head}
            {/* Progress: one bar for each beat. */}
            <div aria-hidden="true" className="mt-6 flex gap-2">
              {story.beats.map((b, i) => (
                <span key={b.tag} className="relative h-0.5 flex-1 overflow-hidden rounded bg-white/10">
                  <span
                    ref={(el) => {
                      bars.current[i] = el;
                    }}
                    className="absolute inset-0 origin-left scale-x-0 bg-alice"
                  />
                </span>
              ))}
            </div>
            <div className="mt-5 grid">
              {story.beats.map((b, i) => (
                <div
                  key={b.tag}
                  ref={(el) => {
                    texts.current[i] = el;
                  }}
                  className="col-start-1 row-start-1"
                  style={{opacity: i === 0 ? 1 : 0}}
                >
                  <p className={`font-mono text-label uppercase ${i === 2 ? 'text-alice' : 'text-faint'}`}>{b.tag}</p>
                  <h3 className="mt-2 text-lead font-semibold text-white">{b.title}</h3>
                  <p className="mt-2 hidden text-body text-muted sm:block">{b.body}</p>
                </div>
              ))}
            </div>
            <div ref={score} className="mt-4 lg:mt-6">
              <p className="font-mono text-label text-faint uppercase">
                Score <span ref={count} className="text-white">3 of 5</span>
              </p>
              <div className="mt-3 hidden lg:block">
                <Score beat={0} />
              </div>
            </div>
          </div>

          <div className="grid min-w-0 rounded-xl border border-line bg-night-2 p-4 shadow-[0_40px_120px_-40px_rgba(0,0,0,.9)] sm:p-6">
            {story.beats.map((b, i) => (
              <div
                key={b.tag}
                aria-hidden={i !== 0 ? true : undefined}
                ref={(el) => {
                  panels.current[i] = el;
                }}
                className="col-start-1 row-start-1 min-w-0"
                style={{opacity: i === 0 ? 1 : 0}}
              >
                <Panel beat={i} />
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
