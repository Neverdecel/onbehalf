import type {MouseEvent} from 'react';
import {hero, links, users} from '../content';
import {scrollToHash} from '../lib/scroll';
import {GitHub} from './Chrome';
import {TermLines} from './Term';

function go(e: MouseEvent<HTMLAnchorElement>) {
  e.preventDefault();
  scrollToHash(e.currentTarget.getAttribute('href') ?? '#top');
}

const colorOf = (name: string) => users.find((u) => u.name === name)?.color;

/**
 * The value first: the headline, the install command, and the real product.
 * One host, one shared stack, and a pane for each user that shows the user.
 */
export function Hero() {
  return (
    <section id="top" className="relative overflow-hidden px-4 pt-28 pb-20 sm:px-6 md:px-[3vw] md:pt-36 md:pb-28">
      <div
        aria-hidden="true"
        className="absolute inset-0 -z-10"
        style={{
          background:
            'radial-gradient(60% 50% at 80% 30%, rgba(165,150,255,.16), transparent 70%), radial-gradient(50% 50% at 10% 80%, rgba(45,212,191,.10), transparent 70%)',
        }}
      />
      <div
        aria-hidden="true"
        className="absolute inset-0 -z-10 opacity-40"
        style={{
          backgroundImage: 'linear-gradient(rgba(255,255,255,.04) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,.04) 1px, transparent 1px)',
          backgroundSize: '48px 48px',
          maskImage: 'radial-gradient(70% 70% at 50% 40%, #000, transparent)',
        }}
      />
      <div className="mx-auto grid max-w-7xl grid-cols-[minmax(0,1fr)] items-center gap-14 lg:grid-cols-[minmax(0,0.95fr)_minmax(0,1.05fr)]">
        <div>
          <p className="font-mono text-label text-alice uppercase">{hero.eyebrow}</p>
          <h1 className="mt-5 font-display text-[clamp(1.875rem,3.6vw,3.5rem)] leading-[1.1] text-white">
            {hero.title}{' '}
            <span className="bg-gradient-to-r from-alice via-shared to-carol bg-clip-text text-transparent">{hero.accent}</span>
          </h1>
          <p className="mt-6 max-w-xl text-lead text-muted">{hero.lead}</p>
          <div className="mt-8 flex flex-wrap gap-3">
            <a href="#start" onClick={go} className="rounded-[4px] bg-white px-5 py-3 font-mono text-label text-night uppercase transition-colors hover:bg-alice">
              Get started
            </a>
            <a href={links.repo} className="inline-flex items-center gap-2 rounded-[4px] border border-white/25 px-5 py-3 font-mono text-label text-white uppercase transition-colors hover:border-white">
              <GitHub className="size-4" />
              View on GitHub
            </a>
          </div>
          <p className="mt-6 inline-block rounded border border-line bg-night-2 px-3 py-2 font-mono text-[0.8125rem] text-ink" aria-label="The command for the guided setup">
            <span className="text-faint">$ </span>
            {hero.install}
          </p>
          <ul className="mt-8 flex flex-wrap gap-x-5 gap-y-2 font-mono text-label text-faint uppercase" aria-label="The parts that onbehalf works with">
            {hero.chips.map((c) => (
              <li key={c}>{c}</li>
            ))}
          </ul>
        </div>

        <div
          role="img"
          aria-label="One host with a shared stack and two panes. In the pane of alice, onbehalf status shows the shared stack, and Git shows alice as the author. In the pane of bob, bob cannot read the GitHub login of alice, and GitHub CLI and Git show bob."
          className="overflow-hidden rounded-xl border border-line bg-night-2 shadow-[0_40px_120px_-40px_rgba(0,0,0,.9)]"
        >
          <div aria-hidden="true" className="flex items-center gap-2 border-b border-line px-4 py-3">
            <span className="flex gap-1.5">
              <i className="block size-2.5 rounded-full bg-white/15" />
              <i className="block size-2.5 rounded-full bg-white/15" />
              <i className="block size-2.5 rounded-full bg-white/15" />
            </span>
            <span className="ml-2 font-mono text-label text-faint uppercase">team-host · one host, each action as its user</span>
          </div>
          <div aria-hidden="true" className="border-b border-shared/30 bg-shared/10 px-4 py-2.5 font-mono text-[0.75rem] text-shared">
            ◆ {hero.shared}
          </div>
          <div aria-hidden="true" className="grid">
            {hero.panes.map((pane, k) => {
              const color = colorOf(pane.user);
              return (
                <div key={pane.user} className="min-w-0 border-t border-line p-4 first:border-t-0">
                  <p className="mb-3 flex items-center gap-2 font-mono text-label uppercase" style={{color}}>
                    <span className="flex size-5 items-center justify-center rounded-full text-[0.625rem] text-night" style={{background: color}}>
                      {pane.user[0].toUpperCase()}
                    </span>
                    {pane.user} · own Unix account
                  </p>
                  <TermLines lines={pane.lines} prompt={pane.user} color={color} typed delay={0.4 + k * 0.2} />
                </div>
              );
            })}
          </div>
        </div>
      </div>
    </section>
  );
}
