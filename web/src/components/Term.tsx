import type {CSSProperties} from 'react';

/** One line of example terminal output. */
export type Line = {t: string; s: string};

const mark: Record<string, string> = {ok: '✓', info: '·'};
const tone: Record<string, string> = {
  cmd: 'text-ink',
  out: 'text-muted',
  ok: 'text-muted',
  info: 'text-faint',
  bad: 'text-bad',
  note: 'text-faint',
};

/**
 * Terminal lines. prompt is the user@host part in front of each command.
 * With typed, the lines come in one after the other (CSS only).
 */
export function TermLines({lines, prompt, color, typed, delay = 0}: {lines: Line[]; prompt?: string; color?: string; typed?: boolean; delay?: number}) {
  return (
    <pre className="overflow-x-auto font-mono text-[0.8125rem] leading-[1.7] whitespace-pre">
      {lines.map((l, i) => {
        const style: CSSProperties | undefined = typed
          ? {animation: `step-in .5s cubic-bezier(.2,.7,.1,1) both`, animationDelay: `${delay + i * 0.45}s`}
          : undefined;
        return (
          <div key={i} className={tone[l.t] ?? 'text-muted'} style={style}>
            {l.t === 'cmd' ? (
              <>
                {prompt ? <span style={{color}}>{prompt}</span> : null}
                <span className="text-faint">$ </span>
                {l.s}
              </>
            ) : mark[l.t] ? (
              <>
                {'  '}
                <span className={l.t === 'ok' ? 'text-ok' : ''}>{mark[l.t]}</span> {l.s}
              </>
            ) : (
              l.s || ' '
            )}
          </div>
        );
      })}
    </pre>
  );
}
