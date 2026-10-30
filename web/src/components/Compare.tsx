import {compare} from '../content';

/** One ring for each point; the option has the bright rings. */
function Rings({count, featured}: {count: number; featured?: boolean}) {
  const total = compare.points.length;
  return (
    <svg viewBox="0 0 120 120" aria-hidden="true" className="size-24">
      {Array.from({length: total}, (_, i) => {
        const on = i < count;
        return (
          <circle
            key={i}
            cx="60"
            cy="60"
            r={14 + i * 10}
            fill="none"
            stroke={on ? (featured ? 'var(--color-alice)' : 'var(--color-ink)') : 'var(--color-line)'}
            strokeOpacity={on ? 0.9 - i * 0.1 : 1}
            strokeWidth={on ? 1.5 : 1}
            strokeDasharray={on ? undefined : '2 4'}
          />
        );
      })}
      <circle cx="60" cy="60" r="4" fill={featured ? 'var(--color-alice)' : 'var(--color-ink)'} />
    </svg>
  );
}

export function Compare() {
  return (
    <section id="why" className="bg-night px-4 py-24 sm:px-6 md:px-[3vw] md:py-36">
      <div className="mx-auto max-w-7xl">
        <div data-reveal>
          <p className="font-mono text-label text-alice uppercase">{compare.eyebrow}</p>
          <h2 className="mt-4 max-w-3xl font-display text-display text-white">{compare.heading}</h2>
          <p className="mt-4 text-body text-muted">{compare.note}</p>
        </div>
        <ul className="mt-12 grid gap-5 lg:grid-cols-3">
          {compare.items.map((item, k) => {
            const count = item.has.filter(Boolean).length;
            return (
              <li
                key={item.name}
                data-reveal
                style={{transitionDelay: `${k * 90}ms`}}
                className={`brackets relative flex flex-col rounded-lg border p-6 sm:p-7 ${
                  item.featured ? 'border-alice/50 bg-[linear-gradient(160deg,rgba(45,212,191,.10),rgba(165,150,255,.08)_60%,transparent)] text-alice' : 'border-line bg-night-2/60 text-white/30'
                }`}
              >
                <div className="flex items-start justify-between gap-4">
                  <h3 className={`font-display text-[1rem] leading-snug tracking-[0.04em] ${item.featured ? 'text-white' : 'text-ink'}`}>{item.name}</h3>
                  <Rings count={count} featured={item.featured} />
                </div>
                <p className="mt-2 font-mono text-label text-faint uppercase">
                  {count} of {item.has.length}
                </p>
                <ul className="mt-6 space-y-3 border-t border-line pt-6">
                  {compare.points.map((pt, i) => (
                    <li key={pt} className="grid grid-cols-[1.25rem_1fr] gap-2 text-body">
                      <span aria-hidden="true" className={item.has[i] ? 'text-ok' : 'text-bad/80'}>
                        {item.has[i] ? '✓' : '✗'}
                      </span>
                      <span className={item.has[i] ? 'text-ink' : 'text-faint line-through decoration-white/20'}>
                        <span className="sr-only">{item.has[i] ? 'Yes: ' : 'No: '}</span>
                        {pt}
                      </span>
                    </li>
                  ))}
                </ul>
              </li>
            );
          })}
        </ul>
      </div>
    </section>
  );
}
