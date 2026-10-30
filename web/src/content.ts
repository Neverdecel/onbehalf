/**
 * All the text on the page. Write it in ASD-STE100 and use the terms of the
 * terminology table in CONTRIBUTING.md. The example users are alice, bob and
 * carol; the example host is team-host.
 */

export const links = {
  repo: 'https://github.com/Neverdecel/onbehalf',
  docs: 'https://github.com/Neverdecel/onbehalf/tree/main/docs',
  release: 'https://github.com/Neverdecel/onbehalf/releases/latest',
  how: 'https://github.com/Neverdecel/onbehalf/blob/main/docs/how-it-works.md',
  features: 'https://github.com/Neverdecel/onbehalf/blob/main/docs/features.md',
  x: 'https://x.com/Neverdecel',
};

export const brand = {
  name: 'onbehalf',
  wordmark: 'ONBEHALF',
  tagline: 'The setup is shared. The identity is not.',
};

export const nav = [
  {label: 'The problem', href: '#problem'},
  {label: 'See it', href: '#see'},
  {label: 'How it works', href: '#how'},
];

/** The three example users. The colours come from @theme in index.css. */
export const users = [
  {name: 'alice', color: 'var(--color-alice)'},
  {name: 'bob', color: 'var(--color-bob)'},
  {name: 'carol', color: 'var(--color-carol)'},
];

export const hero = {
  eyebrow: 'Open source · for teams on one Linux host',
  title: 'One AI setup for the team.',
  accent: 'Each action stays personal.',
  lead: 'onbehalf gives your team one reviewed OpenCode setup on a shared Linux host. The runtime of each user runs as that user, with the logins of that user.',
  install: 'sudo onbehalf setup',
  chips: ['OpenCode', 'LiteLLM', 'Git', 'GitHub CLI', 'Azure CLI', 'Ubuntu and Arch'],
  shared: 'shared stack 3f9c2a1b7e04 · read-only · the same for each user',
  panes: [
    {
      user: 'alice',
      lines: [
        {t: 'cmd', s: 'onbehalf status'},
        {t: 'ok', s: 'shared stack 3f9c2a1b7e04'},
        {t: 'ok', s: 'your gateway key works'},
        {t: 'ok', s: 'OpenCode uses the shared stack'},
        {t: 'cmd', s: 'git log -1 --format=%an'},
        {t: 'out', s: 'alice'},
      ],
    },
    {
      user: 'bob',
      lines: [
        {t: 'cmd', s: 'cat ~alice/.config/gh/hosts.yml'},
        {t: 'bad', s: 'Permission denied'},
        {t: 'cmd', s: 'gh api user -q .login'},
        {t: 'out', s: 'bob'},
        {t: 'cmd', s: 'git log -1 --format=%an'},
        {t: 'out', s: 'bob'},
      ],
    },
  ],
};

/**
 * The scroll story. Each beat is one way to share a setup. The stage and the
 * score change with each beat.
 */
export const story = {
  eyebrow: 'The problem',
  heading: 'A shared setup must not hide who did an action.',
  beats: [
    {
      tag: 'Option 1',
      title: 'A setup on each laptop',
      body: 'Each user keeps a different setup. An improvement stays with one user. Nobody knows which models the team uses, or the cost.',
    },
    {
      tag: 'Option 2',
      title: 'One shared account',
      body: 'The team gets one setup. But each commit shows the shared account. Each user can read the logins of all the other users.',
    },
    {
      tag: 'onbehalf',
      title: 'One shared stack. One account for each user.',
      body: 'The team reviews one setup in Git. Each runtime runs as its user. Each record shows the real user, and each login stays private.',
    },
  ],

  // A blank line between the points keeps each point a sentence of its own
  // for make lint-docs.
  points: [
    'One reviewed setup for the team',

    'Git, GitHub and Azure record the real user',

    'No user can read the logins of a different user',

    'Model use and cost for each user',

    'Offboard without a secret to change',
  ],
  has: [
    [false, true, true, false, true],
    [true, false, false, false, false],
    [true, true, true, true, true],
  ],
};

/** Frames of the reel. Each frame is a short terminal session. */
export const reel = {
  eyebrow: 'See it',
  heading: 'One host. Each action shows its user.',
  body: 'The team shares one setup on one Linux host. Each runtime runs in the Unix account of its user, with the logins of that user.',
  frames: [
    {
      tag: 'operator',
      title: 'Set up the host',
      lines: [
        {t: 'cmd', s: 'sudo onbehalf setup'},
        {t: 'ok', s: 'the model gateway works'},
        {t: 'ok', s: 'installed the shared stack'},
        {t: 'ok', s: 'enrolled alice, bob and carol'},
      ],
    },
    {
      tag: 'alice',
      title: 'Work as alice',
      lines: [
        {t: 'cmd', s: 'onbehalf status'},
        {t: 'ok', s: 'shared stack 3f9c2a1b7e04'},
        {t: 'ok', s: 'your gateway key works'},
        {t: 'cmd', s: 'git log -1 --format=%an'},
        {t: 'out', s: 'alice'},
      ],
    },
    {
      tag: 'bob',
      title: 'Keep each login private',
      lines: [
        {t: 'cmd', s: 'cat ~alice/.config/gh/hosts.yml'},
        {t: 'bad', s: 'Permission denied'},
        {t: 'cmd', s: 'gh api user -q .login'},
        {t: 'out', s: 'bob'},
      ],
    },
    {
      tag: 'operator',
      title: 'See use and cost',
      lines: [
        {t: 'cmd', s: 'sudo onbehalf report'},
        {t: 'out', s: 'user    requests   tokens'},
        {t: 'out', s: 'alice        412     1.9M'},
        {t: 'out', s: 'bob          238     1.1M'},
        {t: 'out', s: 'carol         97     0.4M'},
      ],
    },
    {
      tag: 'operator',
      title: 'Offboard a user',
      lines: [
        {t: 'cmd', s: 'sudo onbehalf user remove carol'},
        {t: 'ok', s: 'locked the account and stopped all processes'},
        {t: 'ok', s: 'revoked all gateway keys'},
        {t: 'info', s: 'alice and bob continue to work'},
      ],
    },
  ],
  note: 'Example output. The numbers are not real.',
};

/** Steps of the flow, in drawing order. */
export const flow = {
  eyebrow: 'How it works',
  heading: 'The runtime acts on behalf of the user who started it.',
  steps: [
    {n: '01', title: 'The team reviews the stack', body: 'The team keeps the harness settings, the instructions, the skills and the model catalog in Git. The host installs them read-only.'},
    {n: '02', title: 'Each user enrolls', body: 'A user enrolls at the first SSH login, or from an Entra group. Each user gets a Unix account and a personal gateway key.'},
    {n: '03', title: 'Each runtime runs as its user', body: 'The OpenCode runtime of each user runs in the Unix account of that user. It uses the logins of that user.'},
    {n: '04', title: 'Each record shows the user', body: 'Git, GitHub, Azure and the model gateway record each action as the user who did it.'},
  ],
  readout: 'Shared credentials',
};

export const start = {
  eyebrow: 'Quick start',
  heading: 'From a fresh host to a team in four steps.',
  steps: [
    {title: 'Install the AI harness', body: 'Install OpenCode one time on the host.'},
    {title: 'Connect a model gateway', body: 'Run a LiteLLM model gateway, or use the gateway of your team.'},
    {title: 'Make a stack source', body: 'Copy examples/stack into a Git repository of your team.'},
    {title: 'Run the guided setup', body: 'The setup connects the gateway, installs the shared stack and adds users.'},
  ],
  commands: [
    {t: 'note', s: '# As the operator of the host'},
    {t: 'cmd', s: 'git clone https://github.com/Neverdecel/onbehalf.git'},
    {t: 'cmd', s: 'cd onbehalf'},
    {t: 'cmd', s: 'sudo ./install.sh --install-deps'},
    {t: 'cmd', s: 'sudo onbehalf setup'},
    {t: 'note', s: ''},
    {t: 'note', s: '# As each user, for example alice'},
    {t: 'cmd', s: 'onbehalf tools'},
    {t: 'cmd', s: 'opencode'},
  ],
  status: 'onbehalf is an early MVP. The repository on GitHub has the code and the docs.',
};
