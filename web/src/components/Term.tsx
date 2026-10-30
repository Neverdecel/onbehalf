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

/** Terminal lines. prompt is the user@host part in front of each command. */
export function TermLines({lines, prompt, color}: {lines: Line[]; prompt?: string; color?: string}) {
  return (
    <pre className="overflow-x-auto font-mono text-[0.8125rem] leading-[1.7] whitespace-pre">
      {lines.map((l, i) => (
        <div key={i} className={tone[l.t] ?? 'text-muted'}>
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
      ))}
    </pre>
  );
}
