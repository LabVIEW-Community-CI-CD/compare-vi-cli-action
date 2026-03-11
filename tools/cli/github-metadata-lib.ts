import { spawnSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import process from 'node:process';
import { ArgumentParser } from 'argparse';
import { z } from 'zod';

export const metadataApplyReportSchemaId = 'github-intake/metadata-apply-report@v1';
const metadataApplyReportSchemaVersion = '1.0.0';

type ContentType = 'Issue' | 'PullRequest';
type OperationStatus = 'not-requested' | 'planned' | 'unchanged' | 'applied' | 'skipped' | 'unsupported' | 'failed';
type ExecutionStatus = 'planned' | 'pass' | 'fail' | 'error';
type SurfaceName = 'issueType' | 'milestone' | 'assignees' | 'reviewers' | 'parentIssue' | 'subIssues';
type ReviewerKind = 'User' | 'Team';
type MutationKind =
  | 'update-issue'
  | 'update-pull-request'
  | 'replace-assignees'
  | 'add-reviewers'
  | 'remove-reviewers'
  | 'add-sub-issue'
  | 'remove-sub-issue';

interface Args {
  url?: string;
  out?: string;
  dry_run?: boolean;
  issue_type?: string;
  clear_issue_type?: boolean;
  milestone?: string;
  clear_milestone?: boolean;
  assignee?: string[];
  clear_assignees?: boolean;
  reviewer?: string[];
  clear_reviewers?: boolean;
  parent?: string;
  clear_parent?: boolean;
  sub_issue?: string[];
  clear_sub_issues?: boolean;
}

interface RequestedScalarSurface<T> {
  active: boolean;
  clear: boolean;
  value: T | null;
}

interface RequestedMetadata {
  issueType: RequestedScalarSurface<string>;
  milestone: RequestedScalarSurface<string>;
  assignees: RequestedScalarSurface<string[]>;
  reviewers: RequestedScalarSurface<string[]>;
  parentIssue: RequestedScalarSurface<string>;
  subIssues: RequestedScalarSurface<string[]>;
}

interface IssueTypeRef {
  id: string;
  name: string;
}

interface MilestoneRef {
  id: string;
  title: string;
  number: number;
  state: string | null;
}

interface EntityRef {
  id: string;
  url: string;
  number: number;
  title: string | null;
}

interface ReviewerRef {
  kind: ReviewerKind;
  key: string;
  login: string;
  teamSlug: string | null;
  organization: string | null;
  display: string;
}

interface GitHubMetadataSnapshot {
  id: string;
  url: string;
  number: number;
  title: string | null;
  contentType: ContentType;
  repository: string;
  repositoryOwner: string;
  repositoryName: string;
  assignees: string[];
  reviewers: ReviewerRef[];
  milestone: MilestoneRef | null;
  issueType: IssueTypeRef | null;
  parentIssue: EntityRef | null;
  subIssues: EntityRef[];
}

interface ResolvedDesiredState {
  issueType: RequestedScalarSurface<IssueTypeRef>;
  milestone: RequestedScalarSurface<MilestoneRef>;
  assignees: RequestedScalarSurface<string[]>;
  reviewers: RequestedScalarSurface<ReviewerRef[]>;
  parentIssue: RequestedScalarSurface<EntityRef>;
  subIssues: RequestedScalarSurface<EntityRef[]>;
}

interface MutationAction {
  kind: MutationKind;
  status: 'planned' | 'applied' | 'failed' | 'skipped';
  summary: string;
  details: Record<string, unknown>;
  error: string | null;
}

interface SurfaceOperation {
  surface: SurfaceName;
  status: OperationStatus;
  applicable: boolean;
  requested: boolean;
  reason: string | null;
  before: unknown;
  desired: unknown;
  after: unknown;
  actions: MutationAction[];
}

interface VerificationField {
  surface: SurfaceName;
  ok: boolean;
  expected: unknown;
  actual: unknown;
}

interface VerificationResult {
  ok: boolean;
  attempts: number;
  delayMs: number;
  maxAttempts: number;
  fields: VerificationField[];
  skipped: boolean;
}

interface RunMetadataApplyResult {
  exitCode: number;
  report: Record<string, unknown>;
  reportPath: string;
  help: boolean;
}

interface RunMetadataApplyOptions {
  argv?: string[];
  now?: Date;
  env?: Record<string, string | undefined>;
  runGhJsonFn?: (args: string[]) => unknown;
  writeJsonFileFn?: (path: string, value: unknown) => void;
}

interface RepositoryCatalog {
  repository: string;
  issueTypes: IssueTypeRef[];
  milestones: MilestoneRef[];
}

const entityRefSchema = z.object({
  id: z.string().min(1),
  url: z.string().url(),
  number: z.number().int().positive(),
  title: z.string().nullable().optional(),
}).transform((value) => ({
  id: value.id,
  url: value.url,
  number: value.number,
  title: value.title ?? null,
}));

const milestoneRefSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1),
  number: z.number().int().positive(),
  state: z.string().nullable().optional(),
}).transform((value) => ({
  id: value.id,
  title: value.title,
  number: value.number,
  state: value.state ?? null,
}));

const issueTypeRefSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
});

const reviewerRequestedSchema = z.object({
  requestedReviewer: z.discriminatedUnion('__typename', [
    z.object({
      __typename: z.literal('User'),
      id: z.string().min(1),
      login: z.string().min(1),
    }),
    z.object({
      __typename: z.literal('Team'),
      id: z.string().min(1),
      slug: z.string().min(1),
      organization: z.object({
        login: z.string().min(1),
      }),
    }),
    z.object({
      __typename: z.literal('Bot'),
      id: z.string().min(1).optional(),
      login: z.string().min(1).optional(),
    }),
  ]).nullable().optional(),
});

const resourceQuerySchema = z.object({
  data: z.object({
    resource: z.object({
      __typename: z.enum(['Issue', 'PullRequest']),
      id: z.string().min(1),
      url: z.string().url(),
      number: z.number().int().positive(),
      title: z.string().nullable().optional(),
      repository: z.object({
        nameWithOwner: z.string().min(1),
        name: z.string().min(1),
        owner: z.object({
          login: z.string().min(1),
        }),
      }),
      assignees: z.object({
        nodes: z.array(z.object({
          id: z.string().min(1),
          login: z.string().min(1),
        })),
      }),
      milestone: milestoneRefSchema.nullable().optional(),
      issueType: issueTypeRefSchema.nullable().optional(),
      parent: entityRefSchema.nullable().optional(),
      subIssues: z.object({
        totalCount: z.number().int().nonnegative().optional(),
        nodes: z.array(entityRefSchema),
      }).optional(),
      reviewRequests: z.object({
        nodes: z.array(reviewerRequestedSchema),
      }).optional(),
    }).nullable(),
  }),
});

const repositoryCatalogSchema = z.object({
  data: z.object({
    repository: z.object({
      nameWithOwner: z.string().min(1),
      issueTypes: z.object({
        nodes: z.array(issueTypeRefSchema),
      }),
      milestones: z.object({
        nodes: z.array(milestoneRefSchema),
      }),
    }).nullable(),
  }),
});

const issueMutationSchema = z.object({
  data: z.object({
    updateIssue: z.object({
      issue: z.object({
        id: z.string().min(1),
      }),
    }),
  }),
});

const pullRequestMutationSchema = z.object({
  data: z.object({
    updatePullRequest: z.object({
      pullRequest: z.object({
        id: z.string().min(1),
      }),
    }),
  }),
});

const replaceActorsMutationSchema = z.object({
  data: z.object({
    replaceActorsForAssignable: z.object({
      assignable: z.object({
        id: z.string().min(1),
      }),
    }),
  }),
});

const addSubIssueMutationSchema = z.object({
  data: z.object({
    addSubIssue: z.object({
      issue: z.object({
        id: z.string().min(1),
      }),
    }),
  }),
});

const removeSubIssueMutationSchema = z.object({
  data: z.object({
    removeSubIssue: z.object({
      issue: z.object({
        id: z.string().min(1),
      }),
    }),
  }),
});

function normalizeText(value: unknown): string | null {
  if (value == null) {
    return null;
  }

  const normalized = String(value).trim();
  return normalized.length > 0 ? normalized : null;
}

function normalizeCliText(value: unknown): string | null {
  const normalized = normalizeText(value);
  if (!normalized || !normalized.includes('^')) {
    return normalized;
  }

  return normalized.replace(/\^(.)/g, '$1').replace(/\^$/g, '').trim();
}

function normalizeGitHubUrl(value: string): string {
  const url = new URL(normalizeCliText(value) ?? value.trim());
  url.hash = '';
  url.search = '';
  return url.toString().replace(/\/$/, '');
}

function resolvePath(filePath: string): string {
  return resolve(process.cwd(), filePath);
}

function writeJsonFile(filePath: string, value: unknown): void {
  mkdirSync(dirname(filePath), { recursive: true });
  writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function sleep(milliseconds: number): void {
  if (!Number.isFinite(milliseconds) || milliseconds <= 0) {
    return;
  }

  const buffer = new SharedArrayBuffer(4);
  const view = new Int32Array(buffer);
  Atomics.wait(view, 0, 0, milliseconds);
}

function normalizeUniqueStrings(values: string[] = []): string[] {
  const seen = new Set<string>();
  const normalized: string[] = [];

  for (const value of values) {
    const trimmed = normalizeCliText(value);
    if (!trimmed) {
      continue;
    }

    const key = trimmed.toLowerCase();
    if (seen.has(key)) {
      continue;
    }

    seen.add(key);
    normalized.push(trimmed);
  }

  return normalized.sort((left, right) => left.localeCompare(right));
}

function normalizeEntityRefs(values: EntityRef[]): EntityRef[] {
  return [...values].sort((left, right) => left.url.localeCompare(right.url));
}

function normalizeReviewerRefs(values: ReviewerRef[]): ReviewerRef[] {
  return [...values].sort((left, right) => left.key.localeCompare(right.key));
}

export function parseReviewerSpecifier(value: string): ReviewerRef {
  const normalized = normalizeCliText(value);
  if (!normalized) {
    throw new Error('Reviewer value cannot be empty.');
  }

  const parts = normalized.split('/');
  if (parts.length === 1) {
    return {
      kind: 'User',
      key: normalized.toLowerCase(),
      login: normalized,
      teamSlug: null,
      organization: null,
      display: normalized,
    };
  }

  if (parts.length === 2 && parts[0] && parts[1]) {
    return {
      kind: 'Team',
      key: `${parts[0].toLowerCase()}/${parts[1].toLowerCase()}`,
      login: `${parts[0]}/${parts[1]}`,
      teamSlug: parts[1],
      organization: parts[0],
      display: `${parts[0]}/${parts[1]}`,
    };
  }

  throw new Error(`Invalid reviewer '${value}'. Use '<login>' or '<org>/<team-slug>'.`);
}

function reviewerKeyForNode(node: z.infer<typeof reviewerRequestedSchema>): ReviewerRef | null {
  const reviewer = node.requestedReviewer;
  if (!reviewer) {
    return null;
  }

  if (reviewer.__typename === 'User') {
    if (!reviewer.login) {
      return null;
    }

    return {
      kind: 'User',
      key: reviewer.login.toLowerCase(),
      login: reviewer.login,
      teamSlug: null,
      organization: null,
      display: reviewer.login,
    };
  }

  if (!reviewer.slug || !reviewer.organization?.login) {
    return null;
  }

  return {
    kind: 'Team',
    key: `${reviewer.organization.login.toLowerCase()}/${reviewer.slug.toLowerCase()}`,
    login: `${reviewer.organization.login}/${reviewer.slug}`,
    teamSlug: reviewer.slug,
    organization: reviewer.organization.login,
    display: `${reviewer.organization.login}/${reviewer.slug}`,
  };
}

function runGhJson(args: string[], env: Record<string, string | undefined> = process.env): unknown {
  const ghScriptPath = env.COMPAREVI_GITHUB_METADATA_GH_SCRIPT;
  const executable = ghScriptPath ? process.execPath : 'gh';
  const commandArgs = ghScriptPath ? [ghScriptPath, ...args] : args;
  const command = [executable, ...commandArgs].join(' ');
  const result = spawnSync(executable, commandArgs, {
    cwd: process.cwd(),
    encoding: 'utf8',
    env,
  });

  if (result.error) {
    const errorMessage = result.error instanceof Error ? result.error.message : String(result.error);
    throw new Error(`Failed to run "${command}": ${errorMessage}`);
  }

  const status = result.status ?? 0;
  const stdout = result.stdout ?? '';
  const stderr = result.stderr ?? '';

  if (status !== 0) {
    const stderrSnippet = stderr.split('\n').slice(0, 10).join('\n').trim();
    const stdoutSnippet = stdout.split('\n').slice(0, 10).join('\n').trim();
    const parts = [`gh command failed: ${command}`, `exit status: ${status}`];
    if (stderrSnippet) {
      parts.push(`stderr:\n${stderrSnippet}`);
    }
    if (stdoutSnippet) {
      parts.push(`stdout:\n${stdoutSnippet}`);
    }
    throw new Error(parts.join('\n\n'));
  }

  try {
    return JSON.parse(stdout);
  } catch (error) {
    const stderrSnippet = stderr.split('\n').slice(0, 10).join('\n').trim();
    const stdoutSnippet = stdout.split('\n').slice(0, 10).join('\n').trim();
    const parts = [
      `Failed to parse JSON from gh command: ${command}`,
      `exit status: ${status}`,
      `parse error: ${(error as Error).message}`,
    ];
    if (stderrSnippet) {
      parts.push(`stderr:\n${stderrSnippet}`);
    }
    if (stdoutSnippet) {
      parts.push(`stdout:\n${stdoutSnippet}`);
    }
    throw new Error(parts.join('\n\n'));
  }
}

function runGhGraphql<T>(
  query: string,
  variables: Record<string, string | number | boolean | null>,
  schema: z.ZodType<T>,
  runGhJsonFn: (args: string[]) => unknown,
): T {
  const args = ['api', 'graphql', '-f', `query=${query}`];
  for (const [key, value] of Object.entries(variables)) {
    if (value === null) {
      args.push('-F', `${key}=null`);
      continue;
    }

    if (typeof value === 'boolean' || typeof value === 'number') {
      args.push('-F', `${key}=${value}`);
      continue;
    }

    args.push('-f', `${key}=${value}`);
  }

  return schema.parse(runGhJsonFn(args));
}

export function parseArgs(argv: string[] = process.argv.slice(2)): Args & { help?: boolean } {
  const parser = new ArgumentParser({
    description: 'Deterministically apply canonical GitHub issue/pull-request metadata for future-agent intake flows.',
  });

  parser.add_argument('--url', {
    required: false,
    help: 'GitHub issue or pull request URL to mutate.',
  });
  parser.add_argument('--out', {
    required: false,
    help: 'Path for the output apply report JSON.',
  });
  parser.add_argument('--dry-run', {
    action: 'store_true',
    help: 'Plan and report the metadata changes without mutating GitHub.',
  });
  parser.add_argument('--issue-type', {
    required: false,
    help: 'Exact issue type name to apply to an issue.',
  });
  parser.add_argument('--clear-issue-type', {
    action: 'store_true',
    help: 'Clear the issue type from an issue.',
  });
  parser.add_argument('--milestone', {
    required: false,
    help: 'Milestone title or number to apply.',
  });
  parser.add_argument('--clear-milestone', {
    action: 'store_true',
    help: 'Clear the milestone from the target.',
  });
  parser.add_argument('--assignee', {
    action: 'append',
    required: false,
    help: 'Exact assignee login. Repeat for multiple assignees. Values are treated as the full desired set.',
  });
  parser.add_argument('--clear-assignees', {
    action: 'store_true',
    help: 'Clear all assignees from the target.',
  });
  parser.add_argument('--reviewer', {
    action: 'append',
    required: false,
    help: "Exact reviewer login or '<org>/<team-slug>'. Repeat for multiple reviewers. Values are treated as the full desired set.",
  });
  parser.add_argument('--clear-reviewers', {
    action: 'store_true',
    help: 'Clear all requested reviewers from a pull request.',
  });
  parser.add_argument('--parent', {
    required: false,
    help: 'Parent issue URL to attach this issue under.',
  });
  parser.add_argument('--clear-parent', {
    action: 'store_true',
    help: 'Detach the issue from its current parent.',
  });
  parser.add_argument('--sub-issue', {
    action: 'append',
    required: false,
    help: 'Child issue URL. Repeat for multiple sub-issues. Values are treated as the full desired set.',
  });
  parser.add_argument('--clear-sub-issues', {
    action: 'store_true',
    help: 'Remove all current sub-issues from the issue.',
  });

  return parser.parse_args(argv) as Args & { help?: boolean };
}

export function resolveRequestedMetadata(args: Args): RequestedMetadata {
  const targetUrl = normalizeText(args.url);
  const normalizedTargetUrl = normalizeCliText(targetUrl);
  if (!normalizedTargetUrl) {
    throw new Error('Metadata apply requires --url <issue-or-pr-url>.');
  }

  const issueType = normalizeCliText(args.issue_type);
  const milestone = normalizeCliText(args.milestone);
  const assignees = normalizeUniqueStrings(args.assignee ?? []);
  const reviewers = normalizeUniqueStrings(args.reviewer ?? []);
  const parent = normalizeCliText(args.parent);
  const subIssues = normalizeUniqueStrings((args.sub_issue ?? []).map((value) => normalizeGitHubUrl(value)));

  if (args.clear_issue_type && issueType) {
    throw new Error('Use either --issue-type or --clear-issue-type, not both.');
  }
  if (args.clear_milestone && milestone) {
    throw new Error('Use either --milestone or --clear-milestone, not both.');
  }
  if (args.clear_assignees && assignees.length > 0) {
    throw new Error('Use either --assignee or --clear-assignees, not both.');
  }
  if (args.clear_reviewers && reviewers.length > 0) {
    throw new Error('Use either --reviewer or --clear-reviewers, not both.');
  }
  if (args.clear_parent && parent) {
    throw new Error('Use either --parent or --clear-parent, not both.');
  }
  if (args.clear_sub_issues && subIssues.length > 0) {
    throw new Error('Use either --sub-issue or --clear-sub-issues, not both.');
  }

  const requested: RequestedMetadata = {
    issueType: {
      active: Boolean(issueType || args.clear_issue_type),
      clear: Boolean(args.clear_issue_type),
      value: issueType,
    },
    milestone: {
      active: Boolean(milestone || args.clear_milestone),
      clear: Boolean(args.clear_milestone),
      value: milestone,
    },
    assignees: {
      active: assignees.length > 0 || Boolean(args.clear_assignees),
      clear: Boolean(args.clear_assignees),
      value: assignees,
    },
    reviewers: {
      active: reviewers.length > 0 || Boolean(args.clear_reviewers),
      clear: Boolean(args.clear_reviewers),
      value: reviewers,
    },
    parentIssue: {
      active: Boolean(parent || args.clear_parent),
      clear: Boolean(args.clear_parent),
      value: parent ? normalizeGitHubUrl(parent) : null,
    },
    subIssues: {
      active: subIssues.length > 0 || Boolean(args.clear_sub_issues),
      clear: Boolean(args.clear_sub_issues),
      value: subIssues,
    },
  };

  const requestedCount = Object.values(requested).filter((surface) => surface.active).length;
  if (requestedCount === 0) {
    throw new Error('No metadata mutation requested. Pass at least one explicit metadata flag.');
  }

  return requested;
}

function queryTarget(url: string, runGhJsonFn: (args: string[]) => unknown): GitHubMetadataSnapshot {
  const query = `
    query($url: URI!) {
      resource(url: $url) {
        __typename
        ... on Issue {
          id
          url
          number
          title
          repository {
            nameWithOwner
            name
            owner { login }
          }
          assignees(first: 100) { nodes { id login } }
          milestone { id title number state }
          issueType { id name }
          parent { id url number title }
          subIssues(first: 100) { totalCount nodes { id url number title } }
        }
        ... on PullRequest {
          id
          url
          number
          title
          repository {
            nameWithOwner
            name
            owner { login }
          }
          assignees(first: 100) { nodes { id login } }
          milestone { id title number state }
          reviewRequests(first: 100) {
            nodes {
              requestedReviewer {
                __typename
                ... on User {
                  id
                  login
                }
                ... on Team {
                  id
                  slug
                  organization {
                    login
                  }
                }
              }
            }
          }
        }
      }
    }
  `;

  const payload = runGhGraphql(query, { url }, resourceQuerySchema, runGhJsonFn);
  if (!payload.data.resource) {
    throw new Error(`GitHub resource not found for ${url}.`);
  }

  const resource = payload.data.resource;
  const reviewers = normalizeReviewerRefs((resource.reviewRequests?.nodes ?? [])
    .map((node) => reviewerKeyForNode(node))
    .filter((value): value is ReviewerRef => Boolean(value)));

  return {
    id: resource.id,
    url: resource.url,
    number: resource.number,
    title: resource.title ?? null,
    contentType: resource.__typename,
    repository: resource.repository.nameWithOwner,
    repositoryOwner: resource.repository.owner.login,
    repositoryName: resource.repository.name,
    assignees: normalizeUniqueStrings(resource.assignees.nodes.map((node) => node.login)),
    reviewers,
    milestone: resource.milestone ? {
      id: resource.milestone.id,
      title: resource.milestone.title,
      number: resource.milestone.number,
      state: resource.milestone.state ?? null,
    } : null,
    issueType: resource.issueType ? {
      id: resource.issueType.id,
      name: resource.issueType.name,
    } : null,
    parentIssue: resource.parent ? {
      id: resource.parent.id,
      url: resource.parent.url,
      number: resource.parent.number,
      title: resource.parent.title ?? null,
    } : null,
    subIssues: normalizeEntityRefs((resource.subIssues?.nodes ?? []).map((node) => ({
      id: node.id,
      url: node.url,
      number: node.number,
      title: node.title ?? null,
    }))),
  };
}

function queryRepositoryCatalog(
  owner: string,
  name: string,
  runGhJsonFn: (args: string[]) => unknown,
): RepositoryCatalog {
  const query = `
    query($owner: String!, $name: String!) {
      repository(owner: $owner, name: $name) {
        nameWithOwner
        issueTypes(first: 100) { nodes { id name } }
        milestones(first: 100, states: [OPEN, CLOSED]) { nodes { id title number state } }
      }
    }
  `;

  const payload = runGhGraphql(query, { owner, name }, repositoryCatalogSchema, runGhJsonFn);
  if (!payload.data.repository) {
    throw new Error(`Repository ${owner}/${name} not found.`);
  }

  return {
    repository: payload.data.repository.nameWithOwner,
    issueTypes: payload.data.repository.issueTypes.nodes
      .map((issueType) => ({ id: issueType.id, name: issueType.name }))
      .sort((left, right) => left.name.localeCompare(right.name)),
    milestones: payload.data.repository.milestones.nodes
      .map((milestone) => ({
        id: milestone.id,
        title: milestone.title,
        number: milestone.number,
        state: milestone.state ?? null,
      }))
      .sort((left, right) => left.number - right.number),
  };
}

function resolveIssueTypeRef(value: RequestedScalarSurface<string>, catalog: RepositoryCatalog): RequestedScalarSurface<IssueTypeRef> {
  if (!value.active) {
    return { active: false, clear: false, value: null };
  }

  if (value.clear) {
    return { active: true, clear: true, value: null };
  }

  const wanted = normalizeText(value.value);
  const match = catalog.issueTypes.find((issueType) => issueType.name.toLowerCase() === wanted?.toLowerCase());
  if (!match) {
    throw new Error(`Issue type '${value.value}' was not found in ${catalog.repository}.`);
  }

  return { active: true, clear: false, value: match };
}

function resolveMilestoneRef(value: RequestedScalarSurface<string>, catalog: RepositoryCatalog): RequestedScalarSurface<MilestoneRef> {
  if (!value.active) {
    return { active: false, clear: false, value: null };
  }

  if (value.clear) {
    return { active: true, clear: true, value: null };
  }

  const wanted = normalizeText(value.value);
  const wantedNumber = wanted && /^\d+$/.test(wanted) ? Number.parseInt(wanted, 10) : null;
  const match = catalog.milestones.find((milestone) => (
    (wantedNumber != null && milestone.number === wantedNumber)
      || milestone.title.toLowerCase() === wanted?.toLowerCase()
  ));
  if (!match) {
    throw new Error(`Milestone '${value.value}' was not found in ${catalog.repository}.`);
  }

  return { active: true, clear: false, value: match };
}

function resolveEntityRefByUrl(url: string, runGhJsonFn: (args: string[]) => unknown): EntityRef {
  const resource = queryTarget(url, runGhJsonFn);
  if (resource.contentType !== 'Issue') {
    throw new Error(`Expected an issue URL for ${url}, but GitHub resolved a ${resource.contentType}.`);
  }

  return {
    id: resource.id,
    url: resource.url,
    number: resource.number,
    title: resource.title,
  };
}

function resolveDesiredState(
  requested: RequestedMetadata,
  target: GitHubMetadataSnapshot,
  runGhJsonFn: (args: string[]) => unknown,
): ResolvedDesiredState {
  const catalog = queryRepositoryCatalog(target.repositoryOwner, target.repositoryName, runGhJsonFn);

  return {
    issueType: resolveIssueTypeRef(requested.issueType, catalog),
    milestone: resolveMilestoneRef(requested.milestone, catalog),
    assignees: requested.assignees.active
      ? {
          active: true,
          clear: requested.assignees.clear,
          value: requested.assignees.clear ? [] : normalizeUniqueStrings(requested.assignees.value ?? []),
        }
      : { active: false, clear: false, value: null },
    reviewers: requested.reviewers.active
      ? {
          active: true,
          clear: requested.reviewers.clear,
          value: requested.reviewers.clear
            ? []
            : normalizeReviewerRefs((requested.reviewers.value ?? []).map((value) => parseReviewerSpecifier(value))),
        }
      : { active: false, clear: false, value: null },
    parentIssue: requested.parentIssue.active
      ? {
          active: true,
          clear: requested.parentIssue.clear,
          value: requested.parentIssue.clear || !requested.parentIssue.value
            ? null
            : resolveEntityRefByUrl(requested.parentIssue.value, runGhJsonFn),
        }
      : { active: false, clear: false, value: null },
    subIssues: requested.subIssues.active
      ? {
          active: true,
          clear: requested.subIssues.clear,
          value: requested.subIssues.clear
            ? []
            : normalizeEntityRefs((requested.subIssues.value ?? []).map((value) => resolveEntityRefByUrl(value, runGhJsonFn))),
        }
      : { active: false, clear: false, value: null },
  };
}

function shallowEntity(entity: EntityRef | null): Record<string, unknown> | null {
  if (!entity) {
    return null;
  }

  return {
    id: entity.id,
    url: entity.url,
    number: entity.number,
    title: entity.title,
  };
}

function shallowMilestone(milestone: MilestoneRef | null): Record<string, unknown> | null {
  if (!milestone) {
    return null;
  }

  return {
    id: milestone.id,
    title: milestone.title,
    number: milestone.number,
    state: milestone.state,
  };
}

function shallowIssueType(issueType: IssueTypeRef | null): Record<string, unknown> | null {
  if (!issueType) {
    return null;
  }

  return {
    id: issueType.id,
    name: issueType.name,
  };
}

function shallowReviewerList(reviewers: ReviewerRef[]): string[] {
  return reviewers.map((reviewer) => reviewer.display);
}

function snapshotToReportShape(snapshot: GitHubMetadataSnapshot): Record<string, unknown> {
  return {
    id: snapshot.id,
    url: snapshot.url,
    number: snapshot.number,
    title: snapshot.title,
    contentType: snapshot.contentType,
    repository: snapshot.repository,
    assignees: [...snapshot.assignees],
    reviewers: shallowReviewerList(snapshot.reviewers),
    milestone: shallowMilestone(snapshot.milestone),
    issueType: shallowIssueType(snapshot.issueType),
    parentIssue: shallowEntity(snapshot.parentIssue),
    subIssues: snapshot.subIssues.map((value) => shallowEntity(value)),
  };
}

function reviewerListsEqual(left: ReviewerRef[], right: ReviewerRef[]): boolean {
  if (left.length !== right.length) {
    return false;
  }

  const leftKeys = left.map((value) => value.key);
  const rightKeys = right.map((value) => value.key);
  return leftKeys.every((value, index) => value === rightKeys[index]);
}

function entityListsEqual(left: EntityRef[], right: EntityRef[]): boolean {
  if (left.length !== right.length) {
    return false;
  }

  return left.every((value, index) => value.url === right[index].url);
}

function cloneSnapshot(snapshot: GitHubMetadataSnapshot): GitHubMetadataSnapshot {
  return {
    ...snapshot,
    assignees: [...snapshot.assignees],
    reviewers: normalizeReviewerRefs(snapshot.reviewers),
    milestone: snapshot.milestone ? { ...snapshot.milestone } : null,
    issueType: snapshot.issueType ? { ...snapshot.issueType } : null,
    parentIssue: snapshot.parentIssue ? { ...snapshot.parentIssue } : null,
    subIssues: normalizeEntityRefs(snapshot.subIssues),
  };
}

function buildSurfaceOperation(
  surface: SurfaceName,
  requested: boolean,
  applicable: boolean,
  before: unknown,
  desired: unknown,
  status: OperationStatus,
  reason: string | null,
  actions: MutationAction[],
): SurfaceOperation {
  return {
    surface,
    requested,
    applicable,
    status,
    reason,
    before,
    desired,
    after: before,
    actions,
  };
}

function plannedAction(kind: MutationKind, summary: string, details: Record<string, unknown>): MutationAction {
  return {
    kind,
    status: 'planned',
    summary,
    details,
    error: null,
  };
}

function arrayDifference<T>(left: T[], right: T[], keyFn: (value: T) => string): { add: T[]; remove: T[] } {
  const leftMap = new Map(left.map((value) => [keyFn(value), value]));
  const rightMap = new Map(right.map((value) => [keyFn(value), value]));

  return {
    add: [...rightMap.entries()].filter(([key]) => !leftMap.has(key)).map(([, value]) => value),
    remove: [...leftMap.entries()].filter(([key]) => !rightMap.has(key)).map(([, value]) => value),
  };
}

export function planMetadataOperations(
  before: GitHubMetadataSnapshot,
  desired: ResolvedDesiredState,
): SurfaceOperation[] {
  const operations: SurfaceOperation[] = [];

  if (!desired.issueType.active) {
    operations.push(buildSurfaceOperation('issueType', false, before.contentType === 'Issue', shallowIssueType(before.issueType), null, 'not-requested', null, []));
  } else if (before.contentType !== 'Issue') {
    operations.push(buildSurfaceOperation('issueType', true, false, shallowIssueType(before.issueType), desired.issueType.value ? shallowIssueType(desired.issueType.value) : null, 'unsupported', 'Issue type can only be applied to issues.', []));
  } else if ((before.issueType?.id ?? null) === (desired.issueType.value?.id ?? null)) {
    operations.push(buildSurfaceOperation('issueType', true, true, shallowIssueType(before.issueType), desired.issueType.value ? shallowIssueType(desired.issueType.value) : null, 'unchanged', null, []));
  } else {
    operations.push(buildSurfaceOperation('issueType', true, true, shallowIssueType(before.issueType), desired.issueType.value ? shallowIssueType(desired.issueType.value) : null, 'planned', null, [
      plannedAction('update-issue', 'Update the issue type.', { issueTypeId: desired.issueType.value?.id ?? null }),
    ]));
  }

  if (!desired.milestone.active) {
    operations.push(buildSurfaceOperation('milestone', false, true, shallowMilestone(before.milestone), null, 'not-requested', null, []));
  } else if ((before.milestone?.id ?? null) === (desired.milestone.value?.id ?? null)) {
    operations.push(buildSurfaceOperation('milestone', true, true, shallowMilestone(before.milestone), desired.milestone.value ? shallowMilestone(desired.milestone.value) : null, 'unchanged', null, []));
  } else {
    operations.push(buildSurfaceOperation('milestone', true, true, shallowMilestone(before.milestone), desired.milestone.value ? shallowMilestone(desired.milestone.value) : null, 'planned', null, [
      plannedAction(before.contentType === 'Issue' ? 'update-issue' : 'update-pull-request', 'Update the milestone.', { milestoneId: desired.milestone.value?.id ?? null }),
    ]));
  }

  if (!desired.assignees.active) {
    operations.push(buildSurfaceOperation('assignees', false, true, [...before.assignees], null, 'not-requested', null, []));
  } else if (before.assignees.length === (desired.assignees.value ?? []).length && before.assignees.every((value, index) => value === (desired.assignees.value ?? [])[index])) {
    operations.push(buildSurfaceOperation('assignees', true, true, [...before.assignees], [...(desired.assignees.value ?? [])], 'unchanged', null, []));
  } else {
    operations.push(buildSurfaceOperation('assignees', true, true, [...before.assignees], [...(desired.assignees.value ?? [])], 'planned', null, [
      plannedAction('replace-assignees', 'Replace the assignee set.', { assignees: [...(desired.assignees.value ?? [])] }),
    ]));
  }

  if (!desired.reviewers.active) {
    operations.push(buildSurfaceOperation('reviewers', false, before.contentType === 'PullRequest', shallowReviewerList(before.reviewers), null, 'not-requested', null, []));
  } else if (before.contentType !== 'PullRequest') {
    operations.push(buildSurfaceOperation('reviewers', true, false, shallowReviewerList(before.reviewers), shallowReviewerList(desired.reviewers.value ?? []), 'unsupported', 'Requested reviewers can only be applied to pull requests.', []));
  } else if (reviewerListsEqual(before.reviewers, desired.reviewers.value ?? [])) {
    operations.push(buildSurfaceOperation('reviewers', true, true, shallowReviewerList(before.reviewers), shallowReviewerList(desired.reviewers.value ?? []), 'unchanged', null, []));
  } else {
    const diff = arrayDifference(before.reviewers, desired.reviewers.value ?? [], (value) => value.key);
    const actions: MutationAction[] = [];
    if (diff.add.length > 0) {
      actions.push(plannedAction('add-reviewers', 'Add missing requested reviewers.', { reviewers: shallowReviewerList(diff.add) }));
    }
    if (diff.remove.length > 0) {
      actions.push(plannedAction('remove-reviewers', 'Remove unexpected requested reviewers.', { reviewers: shallowReviewerList(diff.remove) }));
    }
    operations.push(buildSurfaceOperation('reviewers', true, true, shallowReviewerList(before.reviewers), shallowReviewerList(desired.reviewers.value ?? []), 'planned', null, actions));
  }

  if (!desired.parentIssue.active) {
    operations.push(buildSurfaceOperation('parentIssue', false, before.contentType === 'Issue', shallowEntity(before.parentIssue), null, 'not-requested', null, []));
  } else if (before.contentType !== 'Issue') {
    operations.push(buildSurfaceOperation('parentIssue', true, false, shallowEntity(before.parentIssue), desired.parentIssue.value ? shallowEntity(desired.parentIssue.value) : null, 'unsupported', 'Parent issue linkage can only be applied to issues.', []));
  } else if (desired.parentIssue.value?.id === before.id) {
    operations.push(buildSurfaceOperation('parentIssue', true, true, shallowEntity(before.parentIssue), shallowEntity(desired.parentIssue.value), 'failed', 'An issue cannot be its own parent.', []));
  } else if ((before.parentIssue?.url ?? null) === (desired.parentIssue.value?.url ?? null)) {
    operations.push(buildSurfaceOperation('parentIssue', true, true, shallowEntity(before.parentIssue), desired.parentIssue.value ? shallowEntity(desired.parentIssue.value) : null, 'unchanged', null, []));
  } else if (!desired.parentIssue.value && before.parentIssue) {
    operations.push(buildSurfaceOperation('parentIssue', true, true, shallowEntity(before.parentIssue), null, 'planned', null, [
      plannedAction('remove-sub-issue', 'Detach the issue from its current parent.', { issueId: before.parentIssue.id, subIssueId: before.id }),
    ]));
  } else {
    operations.push(buildSurfaceOperation('parentIssue', true, true, shallowEntity(before.parentIssue), desired.parentIssue.value ? shallowEntity(desired.parentIssue.value) : null, 'planned', null, [
      plannedAction('add-sub-issue', 'Attach the issue to the requested parent.', { issueId: desired.parentIssue.value?.id ?? null, subIssueId: before.id, replaceParent: true }),
    ]));
  }

  if (!desired.subIssues.active) {
    operations.push(buildSurfaceOperation('subIssues', false, before.contentType === 'Issue', before.subIssues.map((value) => shallowEntity(value)), null, 'not-requested', null, []));
  } else if (before.contentType !== 'Issue') {
    operations.push(buildSurfaceOperation('subIssues', true, false, before.subIssues.map((value) => shallowEntity(value)), (desired.subIssues.value ?? []).map((value) => shallowEntity(value)), 'unsupported', 'Sub-issue linkage can only be applied to issues.', []));
  } else if ((desired.subIssues.value ?? []).some((value) => value.id === before.id)) {
    operations.push(buildSurfaceOperation('subIssues', true, true, before.subIssues.map((value) => shallowEntity(value)), (desired.subIssues.value ?? []).map((value) => shallowEntity(value)), 'failed', 'An issue cannot be its own sub-issue.', []));
  } else if (entityListsEqual(before.subIssues, desired.subIssues.value ?? [])) {
    operations.push(buildSurfaceOperation('subIssues', true, true, before.subIssues.map((value) => shallowEntity(value)), (desired.subIssues.value ?? []).map((value) => shallowEntity(value)), 'unchanged', null, []));
  } else {
    const diff = arrayDifference(before.subIssues, desired.subIssues.value ?? [], (value) => value.url);
    const actions: MutationAction[] = [];
    for (const subIssue of diff.remove) {
      actions.push(plannedAction('remove-sub-issue', 'Remove an unexpected sub-issue.', { issueId: before.id, subIssueId: subIssue.id }));
    }
    for (const subIssue of diff.add) {
      actions.push(plannedAction('add-sub-issue', 'Attach a missing sub-issue.', { issueId: before.id, subIssueId: subIssue.id, replaceParent: true }));
    }
    operations.push(buildSurfaceOperation('subIssues', true, true, before.subIssues.map((value) => shallowEntity(value)), (desired.subIssues.value ?? []).map((value) => shallowEntity(value)), 'planned', null, actions));
  }

  return operations;
}

export function projectSnapshotAfterChanges(
  before: GitHubMetadataSnapshot,
  desired: ResolvedDesiredState,
  operations: SurfaceOperation[],
): GitHubMetadataSnapshot {
  const projected = cloneSnapshot(before);
  const successfulSurfaces = new Set(
    operations
      .filter((operation) => operation.status !== 'failed' && operation.status !== 'unsupported' && operation.requested)
      .map((operation) => operation.surface),
  );

  if (successfulSurfaces.has('issueType') && desired.issueType.active && before.contentType === 'Issue') {
    projected.issueType = desired.issueType.value ? { ...desired.issueType.value } : null;
  }
  if (successfulSurfaces.has('milestone') && desired.milestone.active) {
    projected.milestone = desired.milestone.value ? { ...desired.milestone.value } : null;
  }
  if (successfulSurfaces.has('assignees') && desired.assignees.active) {
    projected.assignees = [...(desired.assignees.value ?? [])];
  }
  if (successfulSurfaces.has('reviewers') && desired.reviewers.active && before.contentType === 'PullRequest') {
    projected.reviewers = normalizeReviewerRefs(desired.reviewers.value ?? []);
  }
  if (successfulSurfaces.has('parentIssue') && desired.parentIssue.active && before.contentType === 'Issue') {
    projected.parentIssue = desired.parentIssue.value ? { ...desired.parentIssue.value } : null;
  }
  if (successfulSurfaces.has('subIssues') && desired.subIssues.active && before.contentType === 'Issue') {
    projected.subIssues = normalizeEntityRefs(desired.subIssues.value ?? []);
  }

  return projected;
}

function updateIssueMutation(
  issueId: string,
  input: { issueTypeId?: string | null; milestoneId?: string | null },
  runGhJsonFn: (args: string[]) => unknown,
): void {
  const variableDeclarations = ['$id: ID!'];
  const inputFields = ['id: $id'];

  const variables = { id: issueId } as Record<string, string | null>;
  if (Object.prototype.hasOwnProperty.call(input, 'issueTypeId')) {
    variableDeclarations.push('$issueTypeId: ID');
    inputFields.push('issueTypeId: $issueTypeId');
    variables.issueTypeId = input.issueTypeId ?? null;
  }
  if (Object.prototype.hasOwnProperty.call(input, 'milestoneId')) {
    variableDeclarations.push('$milestoneId: ID');
    inputFields.push('milestoneId: $milestoneId');
    variables.milestoneId = input.milestoneId ?? null;
  }

  const materializedQuery = `
    mutation(${variableDeclarations.join(', ')}) {
      updateIssue(input: {
        ${inputFields.join(',\n        ')}
      }) {
        issue { id }
      }
    }
  `;

  runGhGraphql(materializedQuery, variables, issueMutationSchema, runGhJsonFn);
}

function updatePullRequestMutation(
  pullRequestId: string,
  milestoneId: string | null,
  runGhJsonFn: (args: string[]) => unknown,
): void {
  const query = `
    mutation($pullRequestId: ID!, $milestoneId: ID) {
      updatePullRequest(input: {
        pullRequestId: $pullRequestId,
        milestoneId: $milestoneId
      }) {
        pullRequest { id }
      }
    }
  `;

  const variables = { pullRequestId, milestoneId } as Record<string, string | null>;

  runGhGraphql(query, variables, pullRequestMutationSchema, runGhJsonFn);
}

function replaceAssigneesMutation(
  assignableId: string,
  assignees: string[],
  runGhJsonFn: (args: string[]) => unknown,
): void {
  const query = `
    mutation($assignableId: ID!, $actorLogins: [String!]) {
      replaceActorsForAssignable(input: {
        assignableId: $assignableId,
        actorLogins: $actorLogins
      }) {
        assignable { id }
      }
    }
  `;

  const args = ['api', 'graphql', '-f', `query=${query}`, '-f', `assignableId=${assignableId}`];
  for (const assignee of assignees) {
    args.push('-f', `actorLogins[]=${assignee}`);
  }

  replaceActorsMutationSchema.parse(runGhJsonFn(args));
}

function requestReviewerMutation(
  repository: string,
  pullNumber: number,
  kind: 'POST' | 'DELETE',
  reviewers: ReviewerRef[],
  runGhJsonFn: (args: string[]) => unknown,
): void {
  const args = [
    'api',
    `repos/${repository}/pulls/${pullNumber}/requested_reviewers`,
    '--method',
    kind,
  ];

  const users = reviewers.filter((reviewer) => reviewer.kind === 'User').map((reviewer) => reviewer.login);
  const teams = reviewers.filter((reviewer) => reviewer.kind === 'Team').map((reviewer) => reviewer.teamSlug ?? '');
  for (const reviewer of users) {
    args.push('-f', `reviewers[]=${reviewer}`);
  }
  for (const reviewer of teams) {
    args.push('-f', `team_reviewers[]=${reviewer}`);
  }

  runGhJsonFn(args);
}

function addSubIssueMutation(
  issueId: string,
  subIssueId: string,
  replaceParent: boolean,
  runGhJsonFn: (args: string[]) => unknown,
): void {
  const query = `
    mutation($issueId: ID!, $subIssueId: ID!, $replaceParent: Boolean) {
      addSubIssue(input: {
        issueId: $issueId,
        subIssueId: $subIssueId,
        replaceParent: $replaceParent
      }) {
        issue { id }
      }
    }
  `;

  runGhGraphql(query, {
    issueId,
    subIssueId,
    replaceParent,
  }, addSubIssueMutationSchema, runGhJsonFn);
}

function removeSubIssueMutation(
  issueId: string,
  subIssueId: string,
  runGhJsonFn: (args: string[]) => unknown,
): void {
  const query = `
    mutation($issueId: ID!, $subIssueId: ID!) {
      removeSubIssue(input: {
        issueId: $issueId,
        subIssueId: $subIssueId
      }) {
        issue { id }
      }
    }
  `;

  runGhGraphql(query, {
    issueId,
    subIssueId,
  }, removeSubIssueMutationSchema, runGhJsonFn);
}

function applyOperations(
  before: GitHubMetadataSnapshot,
  operations: SurfaceOperation[],
  desired: ResolvedDesiredState,
  runGhJsonFn: (args: string[]) => unknown,
): void {
  for (const operation of operations) {
    if (operation.status !== 'planned') {
      continue;
    }

    switch (operation.surface) {
      case 'issueType':
        updateIssueMutation(before.id, { issueTypeId: desired.issueType.value?.id ?? null }, runGhJsonFn);
        break;
      case 'milestone':
        if (before.contentType === 'Issue') {
          updateIssueMutation(before.id, { milestoneId: desired.milestone.value?.id ?? null }, runGhJsonFn);
        } else {
          updatePullRequestMutation(before.id, desired.milestone.value?.id ?? null, runGhJsonFn);
        }
        break;
      case 'assignees':
        replaceAssigneesMutation(before.id, desired.assignees.value ?? [], runGhJsonFn);
        break;
      case 'reviewers': {
        const diff = arrayDifference(before.reviewers, desired.reviewers.value ?? [], (value) => value.key);
        if (diff.add.length > 0) {
          requestReviewerMutation(before.repository, before.number, 'POST', diff.add, runGhJsonFn);
        }
        if (diff.remove.length > 0) {
          requestReviewerMutation(before.repository, before.number, 'DELETE', diff.remove, runGhJsonFn);
        }
        break;
      }
      case 'parentIssue':
        if (!desired.parentIssue.value && before.parentIssue) {
          removeSubIssueMutation(before.parentIssue.id, before.id, runGhJsonFn);
        } else if (desired.parentIssue.value) {
          addSubIssueMutation(desired.parentIssue.value.id, before.id, true, runGhJsonFn);
        }
        break;
      case 'subIssues': {
        const diff = arrayDifference(before.subIssues, desired.subIssues.value ?? [], (value) => value.url);
        for (const subIssue of diff.remove) {
          removeSubIssueMutation(before.id, subIssue.id, runGhJsonFn);
        }
        for (const subIssue of diff.add) {
          addSubIssueMutation(before.id, subIssue.id, true, runGhJsonFn);
        }
        break;
      }
      default:
        break;
    }

    operation.status = 'applied';
    operation.actions = operation.actions.map((action) => ({
      ...action,
      status: 'applied',
    }));
  }
}

export function buildVerificationResult(
  expected: GitHubMetadataSnapshot,
  actual: GitHubMetadataSnapshot,
  operations: SurfaceOperation[],
  attempts: number,
  delayMs: number,
  maxAttempts: number,
  skipped: boolean,
): VerificationResult {
  const activeSurfaces = operations.filter((operation) => operation.requested && operation.applicable);
  const fields: VerificationField[] = activeSurfaces.map((operation) => {
    switch (operation.surface) {
      case 'issueType':
        return { surface: operation.surface, ok: (expected.issueType?.id ?? null) === (actual.issueType?.id ?? null), expected: shallowIssueType(expected.issueType), actual: shallowIssueType(actual.issueType) };
      case 'milestone':
        return { surface: operation.surface, ok: (expected.milestone?.id ?? null) === (actual.milestone?.id ?? null), expected: shallowMilestone(expected.milestone), actual: shallowMilestone(actual.milestone) };
      case 'assignees':
        return { surface: operation.surface, ok: expected.assignees.length === actual.assignees.length && expected.assignees.every((value, index) => value === actual.assignees[index]), expected: [...expected.assignees], actual: [...actual.assignees] };
      case 'reviewers':
        return { surface: operation.surface, ok: reviewerListsEqual(expected.reviewers, actual.reviewers), expected: shallowReviewerList(expected.reviewers), actual: shallowReviewerList(actual.reviewers) };
      case 'parentIssue':
        return { surface: operation.surface, ok: (expected.parentIssue?.url ?? null) === (actual.parentIssue?.url ?? null), expected: shallowEntity(expected.parentIssue), actual: shallowEntity(actual.parentIssue) };
      case 'subIssues':
        return { surface: operation.surface, ok: entityListsEqual(expected.subIssues, actual.subIssues), expected: expected.subIssues.map((value) => shallowEntity(value)), actual: actual.subIssues.map((value) => shallowEntity(value)) };
      default:
        return { surface: operation.surface, ok: true, expected: null, actual: null };
    }
  });

  return {
    ok: fields.every((field) => field.ok),
    attempts,
    delayMs,
    maxAttempts,
    fields,
    skipped,
  };
}

function verifyAfterState(
  before: GitHubMetadataSnapshot,
  expected: GitHubMetadataSnapshot,
  operations: SurfaceOperation[],
  runGhJsonFn: (args: string[]) => unknown,
  env: Record<string, string | undefined>,
): { observedAfter: GitHubMetadataSnapshot; verification: VerificationResult } {
  const parsedMaxAttempts = Number.parseInt(env.COMPAREVI_GITHUB_METADATA_VERIFY_ATTEMPTS ?? '5', 10);
  const parsedDelayMs = Number.parseInt(env.COMPAREVI_GITHUB_METADATA_VERIFY_DELAY_MS ?? '500', 10);
  const maxAttempts = Number.isFinite(parsedMaxAttempts) && parsedMaxAttempts > 0 ? parsedMaxAttempts : 5;
  const delayMs = Number.isFinite(parsedDelayMs) && parsedDelayMs >= 0 ? parsedDelayMs : 500;

  let observedAfter = before;
  let verification = buildVerificationResult(expected, observedAfter, operations, 0, delayMs, maxAttempts, false);

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    observedAfter = queryTarget(before.url, runGhJsonFn);
    verification = buildVerificationResult(expected, observedAfter, operations, attempt, delayMs, maxAttempts, false);
    if (verification.ok) {
      return { observedAfter, verification };
    }
    if (attempt < maxAttempts) {
      sleep(delayMs);
    }
  }

  return { observedAfter, verification };
}

function summarizeOperations(operations: SurfaceOperation[]): Record<string, number> {
  const summary: Record<string, number> = {
    requestedCount: 0,
    appliedCount: 0,
    plannedCount: 0,
    unchangedCount: 0,
    unsupportedCount: 0,
    failedCount: 0,
    skippedCount: 0,
  };

  for (const operation of operations) {
    if (operation.requested) {
      summary.requestedCount += 1;
    }
    if (operation.status === 'applied') {
      summary.appliedCount += 1;
    } else if (operation.status === 'planned') {
      summary.plannedCount += 1;
    } else if (operation.status === 'unchanged') {
      summary.unchangedCount += 1;
    } else if (operation.status === 'unsupported') {
      summary.unsupportedCount += 1;
    } else if (operation.status === 'failed') {
      summary.failedCount += 1;
    } else if (operation.status === 'skipped') {
      summary.skippedCount += 1;
    }
  }

  return summary;
}

function executionStatusFor(
  dryRun: boolean,
  operations: SurfaceOperation[],
  verificationOk: boolean,
  hadError: boolean,
): ExecutionStatus {
  if (hadError) {
    return 'error';
  }
  if (operations.some((operation) => operation.status === 'failed' || operation.status === 'unsupported')) {
    return 'fail';
  }
  if (!verificationOk) {
    return 'fail';
  }
  return dryRun ? 'planned' : 'pass';
}

function reportRequestedSurface<T>(surface: RequestedScalarSurface<T>): Record<string, unknown> {
  return {
    active: surface.active,
    clear: surface.clear,
    value: surface.value,
  };
}

function reportResolvedSurface<T>(surface: RequestedScalarSurface<T>, mapper: (value: T) => unknown): Record<string, unknown> {
  return {
    active: surface.active,
    clear: surface.clear,
    value: surface.value == null ? null : mapper(surface.value),
  };
}

export function runMetadataApply({
  argv = process.argv.slice(2),
  now = new Date(),
  env = process.env,
  runGhJsonFn = (args: string[]) => runGhJson(args, env),
  writeJsonFileFn = writeJsonFile,
}: RunMetadataApplyOptions = {}): RunMetadataApplyResult {
  const args = parseArgs(argv);
  const requested = resolveRequestedMetadata(args);
  const outPath = resolvePath(args.out ?? 'tests/results/_agent/issue/github-metadata-apply-report.json');
  const dryRun = Boolean(args.dry_run);
  const targetUrl = normalizeGitHubUrl(args.url ?? '');

  const before = queryTarget(targetUrl, runGhJsonFn);
  const desired = resolveDesiredState(requested, before, runGhJsonFn);
  const operations = planMetadataOperations(before, desired);
  const projectedAfter = projectSnapshotAfterChanges(before, desired, operations);

  let observedAfter: GitHubMetadataSnapshot | null = null;
  let verification: VerificationResult = {
    ok: true,
    attempts: 0,
    delayMs: 0,
    maxAttempts: 0,
    fields: [],
    skipped: true,
  };
  const errors: string[] = [];
  let hadExecutionError = false;

  try {
    if (!dryRun && !operations.some((operation) => operation.status === 'failed' || operation.status === 'unsupported')) {
      applyOperations(before, operations, desired, runGhJsonFn);
      const verifyResult = verifyAfterState(before, projectedAfter, operations, runGhJsonFn, env);
      observedAfter = verifyResult.observedAfter;
      verification = verifyResult.verification;
      if (!verification.ok) {
        errors.push('Observed metadata did not converge to the projected state.');
      }
    }
  } catch (error) {
    hadExecutionError = true;
    errors.push(error instanceof Error ? error.message : String(error));
    try {
      observedAfter = queryTarget(targetUrl, runGhJsonFn);
    } catch {
      observedAfter = null;
    }
  }

  if (dryRun) {
    verification = {
      ok: true,
      attempts: 0,
      delayMs: 0,
      maxAttempts: 0,
      fields: operations
        .filter((operation) => operation.requested && operation.applicable)
        .map((operation) => ({
          surface: operation.surface,
          ok: true,
          expected: operation.after,
          actual: null,
        })),
      skipped: true,
    };
  }

  for (const operation of operations) {
    const snapshot = observedAfter ?? projectedAfter;
    operation.after = (() => {
      switch (operation.surface) {
        case 'issueType':
          return shallowIssueType(snapshot.issueType);
        case 'milestone':
          return shallowMilestone(snapshot.milestone);
        case 'assignees':
          return [...snapshot.assignees];
        case 'reviewers':
          return shallowReviewerList(snapshot.reviewers);
        case 'parentIssue':
          return shallowEntity(snapshot.parentIssue);
        case 'subIssues':
          return snapshot.subIssues.map((value) => shallowEntity(value));
        default:
          return operation.before;
      }
    })();
  }

  const executionStatus = executionStatusFor(dryRun, operations, verification.ok, hadExecutionError);
  const report = {
    schema: metadataApplyReportSchemaId,
    schemaVersion: metadataApplyReportSchemaVersion,
    generatedAt: now.toISOString(),
    dryRun,
    target: {
      url: before.url,
      number: before.number,
      title: before.title,
      contentType: before.contentType,
      repository: before.repository,
      id: before.id,
    },
    requested: {
      issueType: reportRequestedSurface(requested.issueType),
      milestone: reportRequestedSurface(requested.milestone),
      assignees: reportRequestedSurface(requested.assignees),
      reviewers: reportRequestedSurface(requested.reviewers),
      parentIssue: reportRequestedSurface(requested.parentIssue),
      subIssues: reportRequestedSurface(requested.subIssues),
    },
    resolved: {
      issueType: reportResolvedSurface(desired.issueType, (value) => shallowIssueType(value)),
      milestone: reportResolvedSurface(desired.milestone, (value) => shallowMilestone(value)),
      assignees: reportResolvedSurface(desired.assignees, (value) => [...value]),
      reviewers: reportResolvedSurface(desired.reviewers, (value) => shallowReviewerList(value)),
      parentIssue: reportResolvedSurface(desired.parentIssue, (value) => shallowEntity(value)),
      subIssues: reportResolvedSurface(desired.subIssues, (value) => value.map((entry) => shallowEntity(entry))),
    },
    observed: {
      before: snapshotToReportShape(before),
      projectedAfter: snapshotToReportShape(projectedAfter),
      after: observedAfter ? snapshotToReportShape(observedAfter) : null,
    },
    operations,
    verification,
    summary: summarizeOperations(operations),
    execution: {
      status: executionStatus,
      errors,
    },
  };

  writeJsonFileFn(outPath, report);
  return {
    exitCode: executionStatus === 'pass' || executionStatus === 'planned' ? 0 : 1,
    report,
    reportPath: outPath,
    help: false,
  };
}
