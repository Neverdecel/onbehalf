import {useState} from 'react';
import {links, start} from '../content';
import {GitHub} from './Chrome';
import {TermLines} from './Term';

const BASE = import.meta.env.BASE_URL;

export function Start() {
  const [copied, setCopied] = useState(false);
  const copy = async () => {
    const text = start.commands.filter((c) => c.t === 'cmd').map((c) => c.s).join('\n');
    try {
      await navigator.clipboard.writeText(text);
      setCopied(true);
      window.setTimeout(() => setCopied(false), 1600);
    } catch {
      // No clipboard permission: the commands stay on the page to copy by hand.
    }
  };

  return (
    <section id="start" className="relative overflow-hidden px-4 py-24 sm:px-6 md:px-[3vw] md:py-36">
      <div aria-hidden="true" className="absolute inset-0 -z-10" style={{background: 'radial-gradient(70% 60% at 80% 30%, rgba(165,150,255,.12), transparent 70%), radial-gradient(60% 50% at 10% 90%, rgba(45,212,191,.08), transparent 70%)'}} />
      <div className="mx-auto grid max-w-7xl grid-cols-[minmax(0,1fr)] gap-12 md:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)] md:gap-16">
        <div data-reveal>
          <p className="font-mono text-label text-alice uppercase">{start.eyebrow}</p>
          <h2 className="mt-4 font-display text-display text-white">{start.heading}</h2>
          <ol className="mt-10 space-y-6">
            {start.steps.map((s, i) => (
              <li key={s.title} className="grid grid-cols-[2.5rem_1fr]">
                <span className="font-mono text-label text-faint">{String(i + 1).padStart(2, '0')}</span>
                <div>
                  <h3 className="text-lead font-semibold text-white">{s.title}</h3>
                  <p className="mt-1 text-body text-muted">{s.body}</p>
                </div>
              </li>
            ))}
          </ol>
        </div>

        <div data-reveal className="md:self-center" style={{transitionDelay: '120ms'}}>
          <div className="overflow-hidden rounded-xl border border-line bg-night-2 shadow-[0_30px_80px_-30px_rgba(0,0,0,.8)]">
            <div className="flex items-center gap-2 border-b border-line px-4 py-3">
              <span aria-hidden="true" className="flex gap-1.5">
                <i className="block size-2.5 rounded-full bg-white/15" />
                <i className="block size-2.5 rounded-full bg-white/15" />
                <i className="block size-2.5 rounded-full bg-white/15" />
              </span>
              <span className="ml-2 font-mono text-label text-faint uppercase">Quick start</span>
              <button type="button" onClick={copy} className="ml-auto rounded border border-line px-2.5 py-1 font-mono text-label text-white/75 uppercase hover:text-white">
                <span aria-live="polite">{copied ? 'Copied' : 'Copy'}</span>
              </button>
            </div>
            <div className="p-5 sm:p-6" aria-label="The commands for the quick start">
              <TermLines lines={start.commands} />
            </div>
          </div>

          <p className="mt-8 text-body text-muted">{start.status}</p>
          <div className="mt-6 flex flex-wrap gap-3">
            <a href={links.repo} className="inline-flex items-center gap-2 rounded-[4px] bg-white px-5 py-3 font-mono text-label text-night uppercase transition-colors hover:bg-alice">
              <GitHub className="size-4" />
              Get onbehalf on GitHub
            </a>
            <a href={links.docs} className="inline-flex items-center rounded-[4px] border border-white/25 px-5 py-3 font-mono text-label text-white uppercase transition-colors hover:border-white">
              Read the docs
            </a>
            <a href={`${BASE}blog/`} className="inline-flex items-center rounded-[4px] border border-white/25 px-5 py-3 font-mono text-label text-white uppercase transition-colors hover:border-white">
              Read the blog
            </a>
          </div>
        </div>
      </div>
    </section>
  );
}
