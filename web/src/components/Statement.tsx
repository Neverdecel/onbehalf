import {useRef} from 'react';
import {statement, users} from '../content';
import {useFrame} from '../hooks/useFrame';
import {pinProgress, range} from '../lib/scroll';

/**
 * A pinned statement. The words light up one by one with the scroll, then
 * the three users come in under it.
 */
const SECTION_VH = 220;
const WINDOW: [number, number] = [0.08, 0.8];
const DIM = 0.14;

const words = statement.text.split(' ');
const accent = (w: string) => statement.accent.includes(w.replace(/[^a-z]/gi, '').toLowerCase());

export function Statement({reduced}: {reduced: boolean}) {
  const section = useRef<HTMLElement>(null);
  const spans = useRef<(HTMLSpanElement | null)[]>([]);
  const tags = useRef<HTMLDivElement>(null);

  useFrame((y, vh) => {
    if (!section.current) return;
    const p = reduced ? 1 : pinProgress(section.current, y, vh);
    const f = range(p, WINDOW[0], WINDOW[1]) * words.length;
    spans.current.forEach((el, i) => {
      if (!el) return;
      const t = Math.min(1, Math.max(0, f - i));
      el.style.opacity = String(DIM + (1 - DIM) * t);
    });
    const end = range(p, WINDOW[1], WINDOW[1] + 0.1);
    tags.current?.style.setProperty('opacity', String(end));
    tags.current?.style.setProperty('transform', `translate3d(0, ${(1 - end) * 16}px, 0)`);
  });

  let k = 0;
  return (
    <section ref={section} aria-label={statement.eyebrow} style={{height: reduced ? 'auto' : `${SECTION_VH}vh`}} className="relative">
      <div className={reduced ? 'py-24' : 'sticky top-0 flex h-screen-s items-center overflow-hidden'}>
        <div className="mx-auto max-w-6xl px-4 sm:px-6 md:px-[3vw]">
          <p className="font-mono text-label text-alice uppercase">{statement.eyebrow}</p>
          <p className="mt-6 font-display text-[clamp(1.75rem,4.2vw,4rem)] leading-[1.18] text-white">
            {words.map((w, i) => {
              const color = accent(w) ? users[k++ % users.length].color : undefined;
              return (
                <span
                  key={i}
                  ref={(el) => {
                    spans.current[i] = el;
                  }}
                  style={{opacity: reduced ? 1 : DIM, color}}
                >
                  {w}{' '}
                </span>
              );
            })}
          </p>
          <div ref={tags} aria-hidden="true" className="mt-10 flex flex-wrap gap-3 font-mono text-label uppercase" style={{opacity: reduced ? 1 : 0}}>
            {users.map((u) => (
              <span key={u.name} className="rounded-full border px-3 py-1.5" style={{borderColor: u.color, color: u.color}}>
                ✓ {u.name}
              </span>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
