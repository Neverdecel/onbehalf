import {useEffect, useRef} from 'react';
import {reel, users} from '../content';
import {useFrame} from '../hooks/useFrame';
import {pinProgress} from '../lib/scroll';
import {TermLines} from './Term';

/**
 * A reel of terminal frames. The section pins and the track slides
 * sideways with the scroll. The frame nearest the middle of the screen is
 * in focus; the others are dimmed.
 */
const SECTION_VH = 340;
/** The track starts after the heading is in place, and stops before the pin ends. */
const START = 0.08;
const END = 0.92;

function colorOf(tag: string) {
  return users.find((u) => u.name === tag)?.color ?? 'var(--color-shared)';
}

function Frame({f, i}: {f: (typeof reel.frames)[number]; i: number}) {
  const color = colorOf(f.tag);
  return (
    <article
      data-frame
      aria-label={`${i + 1} of ${reel.frames.length}: ${f.title}`}
      className="w-[min(84vw,540px)] shrink-0 snap-center overflow-hidden rounded-xl border border-line bg-night-2 shadow-[0_30px_80px_-30px_rgba(0,0,0,.8)] will-change-transform"
    >
      <div className="flex items-center gap-2 border-b border-line px-4 py-3">
        <span aria-hidden="true" className="flex gap-1.5">
          <i className="block size-2.5 rounded-full bg-white/15" />
          <i className="block size-2.5 rounded-full bg-white/15" />
          <i className="block size-2.5 rounded-full bg-white/15" />
        </span>
        <span className="ml-2 font-mono text-label uppercase" style={{color}}>
          {f.tag}
        </span>
        <span className="ml-auto font-mono text-label text-faint">
          {String(i + 1).padStart(2, '0')}/{String(reel.frames.length).padStart(2, '0')}
        </span>
      </div>
      <div className="px-5 pt-5 pb-6 sm:px-6">
        <h3 className="font-display text-[0.9375rem] tracking-[0.08em] text-white uppercase">{f.title}</h3>
        <div className="mt-4 min-h-[9.5rem]">
          <TermLines lines={f.lines} prompt={`${f.tag === 'operator' ? 'ops' : f.tag}@team-host`} color={color} />
        </div>
      </div>
    </article>
  );
}

export function Reel({reduced}: {reduced: boolean}) {
  const section = useRef<HTMLElement>(null);
  const track = useRef<HTMLDivElement>(null);
  const dots = useRef<HTMLDivElement>(null);
  /** Frame width and gap, measured after each resize, not in the loop. */
  const size = useRef({w: 0, gap: 0});

  useEffect(() => {
    const el = track.current;
    if (!el) return;
    const measure = () => {
      const first = el.querySelector<HTMLElement>('[data-frame]');
      size.current = {w: first?.offsetWidth ?? 0, gap: parseFloat(getComputedStyle(el).columnGap) || 0};
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useFrame((y, vh) => {
    if (reduced || !section.current || !track.current) return;
    const p = pinProgress(section.current, y, vh);
    const n = reel.frames.length;
    const f = Math.min(1, Math.max(0, (p - START) / (END - START))) * (n - 1);
    const {w, gap} = size.current;
    const vw = document.documentElement.clientWidth;
    const x = vw / 2 - (f * (w + gap) + w / 2);
    track.current.style.transform = `translate3d(${x}px, 0, 0)`;
    const frames = track.current.children;
    for (let i = 0; i < frames.length; i++) {
      const d = Math.min(1, Math.abs(i - f));
      const el = frames[i] as HTMLElement;
      el.style.opacity = String(1 - d * 0.62);
      el.style.transform = `scale(${1 - d * 0.08})`;
    }
    const active = Math.round(f);
    dots.current?.querySelectorAll('i').forEach((dot, i) => {
      dot.style.opacity = i === active ? '1' : '0.25';
    });
  });

  const head = (
    <div className="mx-auto max-w-7xl px-4 sm:px-6 md:px-[3vw]">
      <p className="font-mono text-label text-alice uppercase">{reel.eyebrow}</p>
      <h2 className="mt-4 max-w-3xl font-display text-display text-white">{reel.heading}</h2>
      <p className="mt-4 max-w-2xl text-body text-muted">{reel.body}</p>
    </div>
  );

  if (reduced) {
    return (
      <section id="see" ref={section} className="py-24">
        {head}
        <div className="mt-10 flex snap-x snap-mandatory gap-6 overflow-x-auto px-4 pb-4 sm:px-6 md:px-[3vw]">
          {reel.frames.map((f, i) => (
            <Frame key={f.title} f={f} i={i} />
          ))}
        </div>
        <p className="mx-auto mt-4 max-w-7xl px-4 font-mono text-label text-faint uppercase sm:px-6 md:px-[3vw]">{reel.note}</p>
      </section>
    );
  }

  return (
    <section id="see" ref={section} style={{height: `${SECTION_VH}vh`}} className="relative">
      <div className="sticky top-0 flex h-screen-s flex-col justify-center gap-8 overflow-hidden pt-16 sm:gap-12">
        {head}
        <div ref={track} className="flex w-max gap-6 will-change-transform sm:gap-10">
          {reel.frames.map((f, i) => (
            <Frame key={f.title} f={f} i={i} />
          ))}
        </div>
        <div className="mx-auto flex w-full max-w-7xl items-center justify-between px-4 sm:px-6 md:px-[3vw]">
          <p className="font-mono text-label text-faint uppercase">{reel.note}</p>
          <div ref={dots} aria-hidden="true" className="flex gap-2">
            {reel.frames.map((f) => (
              <i key={f.title} className="block h-px w-6 bg-white transition-opacity" />
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
