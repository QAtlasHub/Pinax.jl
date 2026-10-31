// The CLI's arguments: --agent / -a <path> and --comments <path>, each falling back to its
// environment variable (PINAX_AGENT, PINAX_COMMENTS). A flag with no value after it changes nothing.

export interface Args {
  agent: string;
  comments?: string;
}

export function parseArgs(argv: string[], env: NodeJS.ProcessEnv = process.env): Args {
  let agent = env.PINAX_AGENT ?? "";
  let comments = env.PINAX_COMMENTS || undefined;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if ((a === "--agent" || a === "-a") && argv[i + 1] !== undefined) agent = argv[++i];
    else if (a === "--comments" && argv[i + 1] !== undefined) comments = argv[++i];
  }
  return { agent, comments };
}
