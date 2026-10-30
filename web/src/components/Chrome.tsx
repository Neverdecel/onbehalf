import {useState, type MouseEvent} from 'react';
import {brand, links, nav} from '../content';
import {scrollToHash} from '../lib/scroll';

const BASE = import.meta.env.BASE_URL;

function go(e: MouseEvent<HTMLAnchorElement>, then?: () => void) {
  const hash = e.currentTarget.getAttribute('href');
  if (!hash?.startsWith('#')) return;
  e.preventDefault();
  then?.();
  scrollToHash(hash);
}

/** The onbehalf mark: a user with a check. */
export function Mark({className = '', id}: {className?: string; id: string}) {
  return (
    <svg viewBox="0 0 60 60" aria-hidden="true" className={className}>
      <defs>
        <linearGradient id={`mark-${id}`} x1="0" y1="0" x2="1" y2="1">
          <stop offset="0" stopColor="#8b7cf8" />
          <stop offset="1" stopColor="#2dd4bf" />
        </linearGradient>
      </defs>
      <rect width="60" height="60" rx="16" fill={`url(#mark-${id})`} />
      <circle cx="30" cy="23" r="9" fill="#0b1022" />
      <path d="M13 48c1.8-9 8.6-14 17-14s15.2 5 17 14" fill="#0b1022" />
      <circle cx="47" cy="47" r="9" fill="#0b1022" />
      <path d="M42.8 47.2l2.8 2.8 5-5.4" fill="none" stroke="#2dd4bf" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  );
}

function GitHub({className = ''}: {className?: string}) {
  return (
    <svg viewBox="0 0 16 16" aria-hidden="true" className={className}>
      <path
        fill="currentColor"
        d="M8 0C3.58 0 0 3.58 0 8c0 3.54 2.29 6.53 5.47 7.59.4.07.55-.17.55-.38 0-.19-.01-.82-.01-1.49-2.01.37-2.53-.49-2.69-.94-.09-.23-.48-.94-.82-1.13-.28-.15-.68-.52-.01-.53.63-.01 1.08.58 1.23.82.72 1.21 1.87.87 2.33.66.07-.52.28-.87.51-1.07-1.78-.2-3.64-.89-3.64-3.95 0-.87.31-1.59.82-2.15-.08-.2-.36-1.02.08-2.12 0 0 .67-.21 2.2.82.64-.18 1.32-.27 2-.27.68 0 1.36.09 2 .27 1.53-1.04 2.2-.82 2.2-.82.44 1.1.16 1.92.08 2.12.51.56.82 1.27.82 2.15 0 3.07-1.87 3.75-3.65 3.95.29.25.54.73.54 1.48 0 1.07-.01 1.93-.01 2.2 0 .21.15.46.55.38A8.013 8.013 0 0016 8c0-4.42-3.58-8-8-8z"
      />
    </svg>
  );
}

export function Header() {
  const [open, setOpen] = useState(false);
  return (
    <header className="fixed inset-x-0 top-0 z-50 text-white">
      <a href="#main" className="absolute -left-[999px] top-2 rounded bg-night px-3 py-1 focus:left-4">
        Skip to the content
      </a>
      <div className="flex items-center justify-between px-4 pt-4 sm:px-6 sm:pt-5 md:px-[3vw]">
        <a href="#top" onClick={(e) => go(e)} className="flex items-center gap-2.5" aria-label={`${brand.name}: back to the top`}>
          <Mark id="h" className="size-6" />
          <span className="font-display text-[0.875rem] tracking-[0.3em]">{brand.wordmark}</span>
        </a>
        <nav aria-label="Main" className="hidden items-center gap-8 lg:flex">
          {nav.map((item) => (
            <a key={item.href} href={item.href} onClick={(e) => go(e)} className="font-mono text-label text-white/75 uppercase transition-colors hover:text-white">
              {item.label}
            </a>
          ))}
          <a href={links.docs} className="font-mono text-label text-white/75 uppercase transition-colors hover:text-white">
            Docs
          </a>
          <a href={`${BASE}blog/`} className="font-mono text-label text-white/75 uppercase transition-colors hover:text-white">
            Blog
          </a>
          <a href="#start" onClick={(e) => go(e)} className="rounded-[4px] bg-white px-4 py-2.5 font-mono text-label text-night uppercase transition-colors hover:bg-alice">
            Get started
          </a>
        </nav>
        <button
          type="button"
          className="flex size-10 items-center justify-center lg:hidden"
          aria-expanded={open}
          aria-controls="menu"
          aria-label={open ? 'Close the menu' : 'Open the menu'}
          onClick={() => setOpen((v) => !v)}
        >
          <span aria-hidden="true" className="relative block h-3 w-5">
            <span className={`absolute left-0 h-px w-5 bg-white transition-transform ${open ? 'top-1.5 rotate-45' : 'top-0'}`} />
            <span className={`absolute left-0 h-px w-5 bg-white transition-transform ${open ? 'top-1.5 -rotate-45' : 'top-3'}`} />
          </span>
        </button>
      </div>
      <nav
        id="menu"
        aria-label="Menu"
        hidden={!open}
        className="mx-4 mt-3 rounded-lg border border-white/10 bg-night/95 p-2 backdrop-blur lg:hidden"
      >
        {nav.map((item) => (
          <a key={item.href} href={item.href} onClick={(e) => go(e, () => setOpen(false))} className="block rounded px-3 py-3 font-mono text-label text-white/80 uppercase">
            {item.label}
          </a>
        ))}
        <a href={links.docs} className="block rounded px-3 py-3 font-mono text-label text-white/80 uppercase">
          Docs
        </a>
        <a href={`${BASE}blog/`} className="block rounded px-3 py-3 font-mono text-label text-white/80 uppercase">
          Blog
        </a>
        <a href="#start" onClick={(e) => go(e, () => setOpen(false))} className="mt-1 block rounded bg-white px-3 py-3 font-mono text-label text-night uppercase">
          Get started
        </a>
      </nav>
    </header>
  );
}

const footer = [
  {
    title: 'Project',
    items: [
      {label: 'Source code', href: links.repo},
      {label: 'Releases', href: `${links.repo}/releases`},
      {label: 'Changelog', href: `${links.repo}/blob/main/CHANGELOG.md`},
      {label: 'Security', href: `${links.repo}/blob/main/SECURITY.md`},
    ],
  },
  {
    title: 'Docs',
    items: [
      {label: 'How it works', href: links.how},
      {label: 'Operator guide', href: `${links.repo}/blob/main/docs/operator-guide.md`},
      {label: 'User guide', href: `${links.repo}/blob/main/docs/user-guide.md`},
      {label: 'FAQ', href: `${links.repo}/blob/main/docs/faq.md`},
    ],
  },
  {
    title: 'More',
    items: [
      {label: 'Blog', href: `${BASE}blog/`},
      {label: 'RSS feed', href: `${BASE}feed.xml`},
      {label: 'About the author', href: `${BASE}about/`},
      {label: 'X', href: links.x},
    ],
  },
];

export function Footer() {
  return (
    <footer className="border-t border-line bg-night px-4 pt-16 pb-10 sm:px-6 md:px-[3vw]">
      <div className="mx-auto grid max-w-7xl gap-10 md:grid-cols-[1.4fr_1fr_1fr_1fr]">
        <div>
          <a href="#top" onClick={(e) => go(e)} className="flex items-center gap-2.5 text-white">
            <Mark id="f" className="size-6" />
            <span className="font-display text-[0.875rem] tracking-[0.3em]">{brand.wordmark}</span>
          </a>
          <p className="mt-4 max-w-xs text-body text-muted">
            {brand.tagline}
            <br />
            One shared AI harness setup for a team on a Linux host.
          </p>
          <a href={links.repo} className="mt-5 inline-flex items-center gap-2 font-mono text-label text-white/80 uppercase hover:text-white">
            <GitHub className="size-4" />
            GitHub
          </a>
        </div>
        {footer.map((col) => (
          <div key={col.title}>
            <h2 className="font-mono text-label text-faint uppercase">{col.title}</h2>
            <ul className="mt-4 space-y-2.5">
              {col.items.map((item) => (
                <li key={item.label}>
                  <a href={item.href} className="text-body text-muted transition-colors hover:text-white">
                    {item.label}
                  </a>
                </li>
              ))}
            </ul>
          </div>
        ))}
      </div>
      <div className="mx-auto mt-14 flex max-w-7xl flex-col gap-2 border-t border-line pt-6 font-mono text-label text-faint uppercase sm:flex-row sm:justify-between">
        <span>Copyright 2026 Neverdecel. Apache License 2.0.</span>
        <span>No cookies. No tracking.</span>
      </div>
    </footer>
  );
}

export {GitHub};
