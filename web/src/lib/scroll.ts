import Lenis from 'lenis';

/**
 * One rAF loop runs the page. It advances Lenis, then calls each scroll
 * subscriber with the scroll position. The subscribers write styles
 * directly; nothing goes through React state while the page scrolls.
 */
export type Frame = (y: number, vh: number) => void;

const frames = new Set<Frame>();
let lenis: Lenis | null = null;

export function onFrame(fn: Frame): () => void {
  frames.add(fn);
  return () => {
    frames.delete(fn);
  };
}

/** Starts the loop. Returns the cleanup for useEffect. */
export function startScroll(reduced: boolean): () => void {
  // With reduced motion the browser scrolls natively; the loop still runs
  // so that the sections show the correct (static) state.
  if (!reduced) lenis = new Lenis({autoRaf: false, lerp: 0.1});
  invalidate();
  let id = 0;
  const loop = (t: number) => {
    lenis?.raf(t);
    const y = window.scrollY;
    const vh = window.innerHeight;
    frames.forEach((fn) => fn(y, vh));
    id = requestAnimationFrame(loop);
  };
  id = requestAnimationFrame(loop);
  window.addEventListener('resize', invalidate);
  const ro = new ResizeObserver(invalidate);
  ro.observe(document.body);
  return () => {
    cancelAnimationFrame(id);
    window.removeEventListener('resize', invalidate);
    ro.disconnect();
    lenis?.destroy();
    lenis = null;
  };
}

export function scrollToHash(hash: string) {
  const el = hash === '#top' ? null : document.querySelector<HTMLElement>(hash);
  if (hash !== '#top' && !el) return;
  if (lenis) lenis.scrollTo(el ?? 0);
  else if (el) el.scrollIntoView();
  else window.scrollTo(0, 0);
  history.replaceState(null, '', hash === '#top' ? location.pathname : hash);
}

/*
 * Section metrics. A layout read in each frame of each section forces a
 * layout after the style writes of the section before it. So the metrics
 * are measured once, and again only after a resize.
 */
type Metrics = {top: number; height: number};
const cache = new WeakMap<HTMLElement, Metrics & {v: number}>();
let version = 0;

function invalidate() {
  version++;
}

export function metrics(el: HTMLElement): Metrics {
  const hit = cache.get(el);
  if (hit && hit.v === version) return hit;
  const r = el.getBoundingClientRect();
  const m = {top: r.top + window.scrollY, height: r.height, v: version};
  cache.set(el, m);
  return m;
}

/** 0 when the section top reaches the viewport top, 1 when its bottom reaches the viewport bottom. */
export function pinProgress(el: HTMLElement, y: number, vh: number): number {
  const {top, height} = metrics(el);
  return clamp((y - top) / Math.max(1, height - vh));
}

export const clamp = (v: number, lo = 0, hi = 1) => Math.min(hi, Math.max(lo, v));

/** Progress of v through [a, b], clamped to 0..1. */
export const range = (v: number, a: number, b: number) => clamp((v - a) / (b - a));

/** Smoothstep: eases the start and the end of a beat. */
export const ease = (t: number) => t * t * (3 - 2 * t);
