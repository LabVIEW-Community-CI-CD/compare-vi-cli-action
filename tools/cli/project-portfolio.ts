import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { ArgumentParser } from 'argparse';
import { z } from 'zod';

type Mode = 'snapshot' | 'check' | 'apply';
type ApplyFieldSource = 'explicit' | 'config';

const snapshotReportSchemaId = 'project-portfolio-report@v2';
const applyReportSchemaId = 'project-portfolio-apply-report@v1';

const configFieldKeys = [
  'status',
  'program',
  'phase',
  'environmentClass',
  'blockingSignal',
  'evidenceState',
  'portfolioTrack',
] as const;
type ConfigFieldKey = typeof configFieldKeys[number];

const configFieldArgumentMap: Record<ConfigFieldKey, keyof Args> = {
  status: 'status',
  program: 'program',
  phase: 'phase',
  environmentClass: 'environment_class',
  blockingSignal: 'blocking_signal',
  evidenceState: 'evidence_state',
  portfolioTrack: 'portfolio_track',
};

const singleSelectFieldSchema = z.object({
  name: z.string().min(1),
  options: z.array(z.string().min(1)).min(1),
});

const configItemSchema = z.object({
  url: z.string().url(),
  status: z.string().min(1),
  program: z.string().min(1),
  phase: z.string().min(1),
  environmentClass: z.string().min(1),
  blockingSignal: z.string().min(1),
  evidenceState: z.string().min(1),
  portfolioTrack: z.string().min(1),
});

const configSchema = z.object({
  schema: z.literal('project-portfolio-config@v1'),
  owner: z.string().min(1),
  number: z.number().int().positive(),
  title: z.string().min(1),
  shortDescription: z.string().min(1),
  readme: z.string().min(1),
  public: z.boolean(),
  allowAdditionalItems: z.boolean().default(false),
  repositories: z.array(z.string().min(1)).min(1),
  fieldCatalog: z.object({
    status: singleSelectFieldSchema,
    program: singleSelectFieldSchema,
    phase: singleSelectFieldSchema,
    environmentClass: singleSelectFieldSchema,
    blockingSignal: singleSelectFieldSchema,
    evidenceState: singleSelectFieldSchema,
    portfolioTrack: singleSelectFieldSchema,
  }),
  items: z.array(configItemSchema).min(1),
}).superRefine((config, ctx) => {
  for (const [itemIndex, item] of config.items.entries()) {
    for (const fieldKey of configFieldKeys) {
      const fieldCatalog = config.fieldCatalog[fieldKey];
      const fieldValue = item[fieldKey];
      if (!fieldCatalog.options.includes(fieldValue)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          path: ['items', itemIndex, fieldKey],
          message: `Invalid ${fieldKey} '${fieldValue}'. Expected one of [${fieldCatalog.options.join(', ')}].`,
        });
      }
    }
  }
});

const viewSchema = z.object({
  id: z.string().min(1),
  number: z.number().int().positive(),
  title: z.string().min(1),
  shortDescription: z.string().min(1),
  readme: z.string().min(1),
  public: z.boolean(),
  url: z.string().url(),
  items: z.object({ totalCount: z.number().int().nonnegative() }),
  fields: z.object({ totalCount: z.number().int().nonnegative() }),
  owner: z.object({ login: z.string().min(1), type: z.string().min(1) }),
}).passthrough();

const liveSingleSelectOptionSchema = z.object({
  id: z.string().min(1),
  name: z.string().min(1),
});

const fieldsSchema = z.object({
  totalCount: z.number().int().nonnegative(),
  fields: z.array(z.object({
    id: z.string().min(1),
    name: z.string().min(1),
    type: z.string().min(1),
    options: z.array(liveSingleSelectOptionSchema).optional(),
  }).passthrough()),
});

const rawItemSchema = z.object({
  id: z.string().min(1),
  title: z.string().min(1).optional(),
  labels: z.array(z.string()).optional(),
  content: z.object({
    url: z.string().url().optional(),
    title: z.string().min(1).optional(),
    repository: z.string().min(1).optional(),
  }).passthrough().optional(),
}).passthrough();

const itemListSchema = z.object({
  totalCount: z.number().int().nonnegative(),
  items: z.array(rawItemSchema),
});

const resourceQuerySchema = z.object({
  data: z.object({
    resource: z.object({
      __typename: z.enum(['Issue', 'PullRequest']),
      id: z.string().min(1),
      url: z.string().url(),
      title: z.string().min(1).optional(),
      repository: z.object({
        nameWithOwner: z.string().min(1),
      }).optional(),
    }).nullable(),
  }),
});

const addItemMutationSchema = z.object({
  data: z.object({
    addProjectV2ItemById: z.object({
      item: z.object({
        id: z.string().min(1),
      }),
    }),
  }),
});

const updateFieldMutationSchema = z.object({
  data: z.object({
    updateProjectV2ItemFieldValue: z.object({
      projectV2Item: z.object({
        id: z.string().min(1),
      }),
    }),
  }),
});

const itemFieldValuesQuerySchema = z.object({
  data: z.object({
    node: z.object({
      id: z.string().min(1),
      fieldValues: z.object({
        nodes: z.array(z.object({
          __typename: z.string().optional(),
          field: z.object({
            name: z.string().min(1),
          }).optional(),
          name: z.string().optional(),
          optionId: z.string().optional(),
        }).passthrough()),
      }),
    }).nullable(),
  }),
});

type PortfolioConfig = z.infer<typeof configSchema>;
type ConfigItem = z.infer<typeof configItemSchema>;
type ProjectView = z.infer<typeof viewSchema>;
type ProjectFields = z.infer<typeof fieldsSchema>;
type LiveProjectField = ProjectFields['fields'][number];
type RawProjectItem = z.infer<typeof rawItemSchema>;
type ProjectItemList = z.infer<typeof itemListSchema>;
type IssueOrPullRequestResource = NonNullable<z.infer<typeof resourceQuerySchema>['data']['resource']>;

interface Args {
  mode: Mode;
  config?: string;
  out?: string;
  owner?: string;
  number?: number;
  view_file?: string;
  fields_file?: string;
  item_file?: string;
  url?: string;
  use_config?: boolean;
  dry_run?: boolean;
  status?: string;
  program?: string;
  phase?: string;
  environment_class?: string;
  blocking_signal?: string;
  evidence_state?: string;
  portfolio_track?: string;
}

interface NormalizedItem {
  id: string;
  url: string;
  title: string;
  repository: string | null;
  contentType: string | null;
  type: string | null;
  labels: string[];
  assignees: string[];
  reviewers: string[];
  linkedPullRequests: string[];
  milestone: string | null;
  parentIssue: string | null;
  subIssuesProgress: string | null;
  subIssuesProgressSummary: SubIssuesProgressSummary | null;
  status: string | null;
  program: string | null;
  phase: string | null;
  environmentClass: string | null;
  blockingSignal: string | null;
  evidenceState: string | null;
  portfolioTrack: string | null;
}

interface SubIssuesProgressSummary {
  completed: number;
  total: number;
  percent: number | null;
}

interface DriftEntry {
  field: string;
  expected: string | boolean;
  actual: string | boolean | null;
}

interface FieldCatalogDriftEntry {
  field: ConfigFieldKey;
  expectedName: string;
  actualName: string | null;
  missing: boolean;
  missingOptions: string[];
  unexpectedOptions: string[];
}

type FieldNameMap = Record<ConfigFieldKey, string>;

interface ResolvedLiveField {
  key: ConfigFieldKey;
  fieldId: string;
  fieldName: string;
  optionIdByName: Map<string, string>;
  liveOptions: string[];
}

type ResolvedLiveFieldMap = Record<ConfigFieldKey, ResolvedLiveField>;

interface RequestedApplyField {
  key: ConfigFieldKey;
  value: string;
  source: ApplyFieldSource;
}

interface ResolvedApplyField extends RequestedApplyField {
  fieldId: string;
  fieldName: string;
  optionId: string;
}

interface ResolvedApplyTarget {
  resource: IssueOrPullRequestResource;
  existingItem: NormalizedItem | null;
  itemId: string | null;
  added: boolean;
  wouldAdd: boolean;
}

interface VerifiedApplyFieldState {
  key: ConfigFieldKey;
  fieldName: string;
  expectedValue: string;
  expectedOptionId: string;
  actualValue: string | null;
  actualOptionId: string | null;
  ok: boolean;
}

interface ApplyVerificationResult {
  ok: boolean;
  attempts: number;
  delayMs: number;
  fields: VerifiedApplyFieldState[];
}

interface BoardContext {
  contentType: string | null;
  type: string | null;
  milestone: string | null;
  hasMilestone: boolean;
  assigneeCount: number;
  reviewerCount: number;
  linkedPullRequestCount: number;
  hasParentIssue: boolean;
  hasSubIssuesProgress: boolean;
  subIssuesCompleted: number | null;
  subIssuesTotal: number | null;
  subIssuesPercent: number | null;
}

interface ProjectContext {
  view: ProjectView;
  fields: ProjectFields;
  itemList: ProjectItemList;
  normalizedItems: NormalizedItem[];
}

function readJsonFile<T>(filePath: string): T {
  return JSON.parse(readFileSync(filePath, 'utf8')) as T;
}

function writeJsonFile(filePath: string, value: unknown): void {
  mkdirSync(dirname(filePath), { recursive: true });
  writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function resolvePath(maybeRelative: string): string {
  return resolve(process.cwd(), maybeRelative);
}

function normalizeGitHubUrl(url: string): string {
  const parsed = new URL(url);
  parsed.hash = '';
  parsed.search = '';
  if (parsed.pathname !== '/' && parsed.pathname.endsWith('/')) {
    parsed.pathname = parsed.pathname.slice(0, -1);
  }
  return parsed.toString();
}

function normalizeComparableUrl(value: string): string {
  try {
    return normalizeGitHubUrl(value);
  } catch {
    return value.trim();
  }
}

function sleep(milliseconds: number): void {
  if (milliseconds <= 0) {
    return;
  }

  const buffer = new SharedArrayBuffer(4);
  const view = new Int32Array(buffer);
  Atomics.wait(view, 0, 0, milliseconds);
}

function runGhJson(args: string[]): unknown {
  const ghScriptPath = process.env.COMPAREVI_PROJECT_PORTFOLIO_GH_SCRIPT;
  const executable = ghScriptPath ? process.execPath : 'gh';
  const commandArgs = ghScriptPath ? [ghScriptPath, ...args] : args;
  const command = [executable, ...commandArgs].join(' ');
  const result = spawnSync(executable, commandArgs, {
    cwd: process.cwd(),
    encoding: 'utf8',
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
    const parts = [
      `gh command failed: ${command}`,
      `exit status: ${status}`,
    ];

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

function runGhGraphql<T>(query: string, variables: Record<string, string>, schema: z.ZodType<T>): T {
  const args = ['api', 'graphql', '-f', `query=${query}`];
  for (const [key, value] of Object.entries(variables)) {
    args.push('-f', `${key}=${value}`);
  }

  return schema.parse(runGhJson(args));
}

function loadJsonInput<T>(
  maybeFile: string | undefined,
  schema: z.ZodType<T>,
  ghArgs: string[],
): T {
  const payload = maybeFile ? readJsonFile<unknown>(resolvePath(maybeFile)) : runGhJson(ghArgs);
  return schema.parse(payload);
}

function fieldValue(item: RawProjectItem, name: string): string | null {
  const normalizedName = name.trim().toLowerCase();
  const match = Object.entries(item).find(([key]) => key.trim().toLowerCase() === normalizedName);
  return typeof match?.[1] === 'string' ? match[1] : null;
}

function fieldArrayValue(item: RawProjectItem, name: string): string[] {
  const normalizedName = name.trim().toLowerCase();
  const match = Object.entries(item).find(([key]) => key.trim().toLowerCase() === normalizedName);
  return Array.isArray(match?.[1])
    ? match[1].filter((value): value is string => typeof value === 'string')
    : [];
}

function parseSubIssuesProgress(value: string | null): SubIssuesProgressSummary | null {
  if (!value) {
    return null;
  }

  const match = value.match(/^\s*(\d+)\s*\/\s*(\d+)\s*$/);
  if (!match) {
    return null;
  }

  const completed = Number.parseInt(match[1] ?? '', 10);
  const total = Number.parseInt(match[2] ?? '', 10);
  const percent = total > 0 ? Number((completed / total).toFixed(4)) : null;
  return { completed, total, percent };
}

function buildFieldNameMap(config: PortfolioConfig): FieldNameMap {
  return {
    status: config.fieldCatalog.status.name,
    program: config.fieldCatalog.program.name,
    phase: config.fieldCatalog.phase.name,
    environmentClass: config.fieldCatalog.environmentClass.name,
    blockingSignal: config.fieldCatalog.blockingSignal.name,
    evidenceState: config.fieldCatalog.evidenceState.name,
    portfolioTrack: config.fieldCatalog.portfolioTrack.name,
  };
}

function normalizeItem(item: RawProjectItem, fieldNames: FieldNameMap): NormalizedItem {
  const content = item.content ?? {};
  const subIssuesProgress = fieldValue(item, 'Sub-issues progress');
  return {
    id: item.id,
    url: typeof content.url === 'string' ? content.url : `project-item:${item.id}`,
    title: typeof item.title === 'string' ? item.title : typeof content.title === 'string' ? content.title : item.id,
    repository: typeof content.repository === 'string' ? content.repository : null,
    contentType: typeof content.type === 'string' ? content.type : null,
    type: fieldValue(item, 'Type'),
    labels: Array.isArray(item.labels) ? item.labels.filter((value): value is string => typeof value === 'string') : [],
    assignees: fieldArrayValue(item, 'Assignees'),
    reviewers: fieldArrayValue(item, 'Reviewers'),
    linkedPullRequests: fieldArrayValue(item, 'Linked pull requests'),
    milestone: fieldValue(item, 'Milestone'),
    parentIssue: fieldValue(item, 'Parent issue'),
    subIssuesProgress,
    subIssuesProgressSummary: parseSubIssuesProgress(subIssuesProgress),
    status: fieldValue(item, fieldNames.status),
    program: fieldValue(item, fieldNames.program),
    phase: fieldValue(item, fieldNames.phase),
    environmentClass: fieldValue(item, fieldNames.environmentClass),
    blockingSignal: fieldValue(item, fieldNames.blockingSignal),
    evidenceState: fieldValue(item, fieldNames.evidenceState),
    portfolioTrack: fieldValue(item, fieldNames.portfolioTrack),
  };
}

function resolveConfigItemByUrl(config: PortfolioConfig, url: string): ConfigItem | null {
  const normalizedTargetUrl = normalizeComparableUrl(url);
  return config.items.find((item) => normalizeComparableUrl(item.url) === normalizedTargetUrl) ?? null;
}

function getArgumentString(args: Args, key: keyof Args): string | null {
  const value = args[key];
  if (typeof value !== 'string') {
    return null;
  }

  const trimmedValue = value.trim();
  return trimmedValue.length > 0 ? trimmedValue : null;
}

function normalizeExplicitFieldValue(value: string, allowedValues: string[]): string {
  const trimmedValue = value.trim();
  if (!trimmedValue.includes('^')) {
    return trimmedValue;
  }

  const normalizedValue = trimmedValue.replace(/\^/g, '').trim();
  return allowedValues.includes(normalizedValue) ? normalizedValue : trimmedValue;
}

function resolveRequestedApplyFields(args: Args, config: PortfolioConfig, targetUrl: string): RequestedApplyField[] {
  const configItem = resolveConfigItemByUrl(config, targetUrl);
  if (args.use_config && !configItem) {
    const configPath = resolvePath(args.config ?? 'tools/priority/project-portfolio.json');
    throw new Error(`Config item not found for ${targetUrl}. Add it to ${configPath} or pass explicit field values.`);
  }

  const resolved: RequestedApplyField[] = [];
  for (const fieldKey of configFieldKeys) {
    const allowedValues = config.fieldCatalog[fieldKey].options;
    const explicitValue = getArgumentString(args, configFieldArgumentMap[fieldKey]);
    if (explicitValue) {
      resolved.push({
        key: fieldKey,
        value: normalizeExplicitFieldValue(explicitValue, allowedValues),
        source: 'explicit',
      });
      continue;
    }

    if (args.use_config && configItem) {
      resolved.push({
        key: fieldKey,
        value: configItem[fieldKey],
        source: 'config',
      });
    }
  }

  if (resolved.length === 0) {
    throw new Error('No apply fields were requested. Pass --use-config and/or explicit field flags such as --status or --program.');
  }

  for (const field of resolved) {
    const fieldAllowedValues = config.fieldCatalog[field.key].options;
    if (!fieldAllowedValues.includes(field.value)) {
      throw new Error(`Invalid ${field.key} '${field.value}'. Expected one of [${fieldAllowedValues.join(', ')}].`);
    }
  }

  return resolved;
}

function resolveLiveFields(config: PortfolioConfig, fields: ProjectFields): ResolvedLiveFieldMap {
  const fieldByName = new Map<string, LiveProjectField>(
    fields.fields.map((field) => [field.name.trim().toLowerCase(), field]),
  );

  const resolved = {} as ResolvedLiveFieldMap;
  for (const fieldKey of configFieldKeys) {
    const configuredField = config.fieldCatalog[fieldKey];
    const liveField = fieldByName.get(configuredField.name.trim().toLowerCase());
    if (!liveField) {
      throw new Error(`Live project field '${configuredField.name}' was not found for ${fieldKey}.`);
    }
    if (liveField.type !== 'ProjectV2SingleSelectField') {
      throw new Error(`Live project field '${configuredField.name}' is ${liveField.type}, expected ProjectV2SingleSelectField.`);
    }

    const liveOptions = Array.isArray(liveField.options) ? liveField.options : [];
    const optionIdByName = new Map<string, string>();
    for (const option of liveOptions) {
      optionIdByName.set(option.name, option.id);
    }

    resolved[fieldKey] = {
      key: fieldKey,
      fieldId: liveField.id,
      fieldName: liveField.name,
      optionIdByName,
      liveOptions: liveOptions.map((option) => option.name),
    };
  }

  return resolved;
}

function resolveApplyFieldUpdates(
  requestedFields: RequestedApplyField[],
  liveFields: ResolvedLiveFieldMap,
): ResolvedApplyField[] {
  return requestedFields.map((requestedField) => {
    const liveField = liveFields[requestedField.key];
    const optionId = liveField.optionIdByName.get(requestedField.value);
    if (!optionId) {
      throw new Error(
        `Live project field '${liveField.fieldName}' does not expose option '${requestedField.value}'. Available options: [${liveField.liveOptions.join(', ')}].`,
      );
    }

    return {
      ...requestedField,
      fieldId: liveField.fieldId,
      fieldName: liveField.fieldName,
      optionId,
    };
  });
}

function resolveProjectResource(url: string): IssueOrPullRequestResource {
  const response = runGhGraphql(
    `
      query($url: URI!) {
        resource(url: $url) {
          __typename
          ... on Issue {
            id
            url
            title
            repository {
              nameWithOwner
            }
          }
          ... on PullRequest {
            id
            url
            title
            repository {
              nameWithOwner
            }
          }
        }
      }
    `,
    { url },
    resourceQuerySchema,
  );

  if (!response.data.resource) {
    throw new Error(`GitHub resource not found for ${url}.`);
  }

  return response.data.resource;
}

function addProjectItem(projectId: string, contentId: string): string {
  const response = runGhGraphql(
    `
      mutation($projectId: ID!, $contentId: ID!) {
        addProjectV2ItemById(input: { projectId: $projectId, contentId: $contentId }) {
          item {
            id
          }
        }
      }
    `,
    { projectId, contentId },
    addItemMutationSchema,
  );

  return response.data.addProjectV2ItemById.item.id;
}

function updateProjectFieldValue(projectId: string, itemId: string, fieldId: string, optionId: string): string {
  const response = runGhGraphql(
    `
      mutation($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
        updateProjectV2ItemFieldValue(
          input: {
            projectId: $projectId
            itemId: $itemId
            fieldId: $fieldId
            value: { singleSelectOptionId: $optionId }
          }
        ) {
          projectV2Item {
            id
          }
        }
      }
    `,
    { projectId, itemId, fieldId, optionId },
    updateFieldMutationSchema,
  );

  return response.data.updateProjectV2ItemFieldValue.projectV2Item.id;
}

function readProjectItemFieldValues(itemId: string): Map<string, { value: string; optionId: string | null }> {
  const response = runGhGraphql(
    `
      query($itemId: ID!) {
        node(id: $itemId) {
          ... on ProjectV2Item {
            id
            fieldValues(first: 50) {
              nodes {
                __typename
                ... on ProjectV2ItemFieldSingleSelectValue {
                  field {
                    ... on ProjectV2SingleSelectField {
                      name
                    }
                  }
                  name
                  optionId
                }
              }
            }
          }
        }
      }
    `,
    { itemId },
    itemFieldValuesQuerySchema,
  );

  if (!response.data.node) {
    throw new Error(`Project item ${itemId} was not found when verifying applied fields.`);
  }

  const values = new Map<string, { value: string; optionId: string | null }>();
  for (const fieldValue of response.data.node.fieldValues.nodes) {
    if (!fieldValue.field?.name || typeof fieldValue.name !== 'string') {
      continue;
    }

    values.set(fieldValue.field.name, {
      value: fieldValue.name,
      optionId: typeof fieldValue.optionId === 'string' ? fieldValue.optionId : null,
    });
  }

  return values;
}

function buildVerifiedApplyFieldStates(
  updates: ResolvedApplyField[],
  actualFieldValues: Map<string, { value: string; optionId: string | null }>,
): VerifiedApplyFieldState[] {
  return updates.map((update) => {
    const actualField = actualFieldValues.get(update.fieldName);
    return {
      key: update.key,
      fieldName: update.fieldName,
      expectedValue: update.value,
      expectedOptionId: update.optionId,
      actualValue: actualField?.value ?? null,
      actualOptionId: actualField?.optionId ?? null,
      ok: actualField?.value === update.value && actualField?.optionId === update.optionId,
    };
  });
}

function verifyAppliedFields(
  projectId: string,
  itemId: string,
  updates: ResolvedApplyField[],
): ApplyVerificationResult {
  const parsedMaxAttempts = Number.parseInt(process.env.COMPAREVI_PROJECT_PORTFOLIO_VERIFY_ATTEMPTS ?? '5', 10);
  const parsedDelayMs = Number.parseInt(process.env.COMPAREVI_PROJECT_PORTFOLIO_VERIFY_DELAY_MS ?? '500', 10);
  const maxAttempts = Math.max(1, Number.isNaN(parsedMaxAttempts) ? 5 : parsedMaxAttempts);
  const delayMs = Math.max(0, Number.isNaN(parsedDelayMs) ? 500 : parsedDelayMs);

  let lastFieldStates: VerifiedApplyFieldState[] = [];
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const actualFieldValues = readProjectItemFieldValues(itemId);
    lastFieldStates = buildVerifiedApplyFieldStates(updates, actualFieldValues);
    const missingOrMismatched = lastFieldStates.filter((fieldState) => !fieldState.ok);
    if (missingOrMismatched.length === 0) {
      return {
        ok: true,
        attempts: attempt,
        delayMs,
        fields: lastFieldStates,
      };
    }

    if (attempt >= maxAttempts) {
      break;
    }

    for (const fieldState of missingOrMismatched) {
      const update = updates.find((candidate) => candidate.key === fieldState.key);
      if (update) {
        updateProjectFieldValue(projectId, itemId, update.fieldId, update.optionId);
      }
    }
    sleep(delayMs);
  }

  return {
    ok: false,
    attempts: maxAttempts,
    delayMs,
    fields: lastFieldStates,
  };
}

function resolveApplyTarget(
  view: ProjectView,
  normalizedItems: NormalizedItem[],
  targetUrl: string,
  dryRun: boolean,
): ResolvedApplyTarget {
  const resource = resolveProjectResource(targetUrl);
  const normalizedResourceUrl = normalizeComparableUrl(resource.url);
  const existingItem = normalizedItems.find((item) => normalizeComparableUrl(item.url) === normalizedResourceUrl) ?? null;

  if (existingItem) {
    return {
      resource,
      existingItem,
      itemId: existingItem.id,
      added: false,
      wouldAdd: false,
    };
  }

  if (dryRun) {
    return {
      resource,
      existingItem: null,
      itemId: null,
      added: false,
      wouldAdd: true,
    };
  }

  const itemId = addProjectItem(view.id, resource.id);
  return {
    resource,
    existingItem: null,
    itemId,
    added: true,
    wouldAdd: false,
  };
}

function cloneNormalizedItem(item: NormalizedItem): NormalizedItem {
  return {
    ...item,
    labels: [...item.labels],
    assignees: [...item.assignees],
    reviewers: [...item.reviewers],
    linkedPullRequests: [...item.linkedPullRequests],
    subIssuesProgressSummary: item.subIssuesProgressSummary ? { ...item.subIssuesProgressSummary } : null,
  };
}

function createSkeletonItem(resource: IssueOrPullRequestResource, itemId: string | null): NormalizedItem {
  return {
    id: itemId ?? `pending:${resource.id}`,
    url: resource.url,
    title: resource.title ?? resource.url,
    repository: resource.repository?.nameWithOwner ?? null,
    contentType: resource.__typename,
    type: null,
    labels: [],
    assignees: [],
    reviewers: [],
    linkedPullRequests: [],
    milestone: null,
    parentIssue: null,
    subIssuesProgress: null,
    subIssuesProgressSummary: null,
    status: null,
    program: null,
    phase: null,
    environmentClass: null,
    blockingSignal: null,
    evidenceState: null,
    portfolioTrack: null,
  };
}

function buildProjectedItemSnapshot(
  resource: IssueOrPullRequestResource,
  existingItem: NormalizedItem | null,
  itemId: string | null,
  updates: ResolvedApplyField[],
): NormalizedItem {
  const projectedItem = existingItem ? cloneNormalizedItem(existingItem) : createSkeletonItem(resource, itemId);

  for (const update of updates) {
    switch (update.key) {
      case 'status':
        projectedItem.status = update.value;
        break;
      case 'program':
        projectedItem.program = update.value;
        break;
      case 'phase':
        projectedItem.phase = update.value;
        break;
      case 'environmentClass':
        projectedItem.environmentClass = update.value;
        break;
      case 'blockingSignal':
        projectedItem.blockingSignal = update.value;
        break;
      case 'evidenceState':
        projectedItem.evidenceState = update.value;
        break;
      case 'portfolioTrack':
        projectedItem.portfolioTrack = update.value;
        break;
      default:
        throw new Error(`Unsupported apply field key '${String(update.key)}'.`);
    }
  }

  return projectedItem;
}

function buildBoardContext(item: NormalizedItem | null, resource?: IssueOrPullRequestResource): BoardContext {
  return {
    contentType: item?.contentType ?? resource?.__typename ?? null,
    type: item?.type ?? null,
    milestone: item?.milestone ?? null,
    hasMilestone: Boolean(item?.milestone),
    assigneeCount: item?.assignees.length ?? 0,
    reviewerCount: item?.reviewers.length ?? 0,
    linkedPullRequestCount: item?.linkedPullRequests.length ?? 0,
    hasParentIssue: Boolean(item?.parentIssue),
    hasSubIssuesProgress: Boolean(item?.subIssuesProgress),
    subIssuesCompleted: item?.subIssuesProgressSummary?.completed ?? null,
    subIssuesTotal: item?.subIssuesProgressSummary?.total ?? null,
    subIssuesPercent: item?.subIssuesProgressSummary?.percent ?? null,
  };
}

function reloadObservedItemSnapshot(args: Args, config: PortfolioConfig, itemId: string, targetUrl: string): NormalizedItem | null {
  if (args.item_file) {
    return null;
  }

  const owner = args.owner ?? config.owner;
  const number = args.number ?? config.number;
  const itemList = loadJsonInput(
    undefined,
    itemListSchema,
    ['project', 'item-list', String(number), '--owner', owner, '--limit', '100', '--format', 'json'],
  );
  const fieldNames = buildFieldNameMap(config);
  const normalizedItems = itemList.items.map((item) => normalizeItem(item, fieldNames));
  const normalizedTargetUrl = normalizeComparableUrl(targetUrl);
  return normalizedItems.find((item) => item.id === itemId || normalizeComparableUrl(item.url) === normalizedTargetUrl) ?? null;
}

function compareProject(
  config: PortfolioConfig,
  view: ProjectView,
  fields: ProjectFields,
  items: NormalizedItem[],
) {
  const actualByUrl = new Map(items.map((item) => [item.url, item]));
  const expectedByUrl = new Map(config.items.map((item) => [item.url, item]));
  const metadata: DriftEntry[] = [];

  if (view.title !== config.title) {
    metadata.push({ field: 'title', expected: config.title, actual: view.title });
  }
  if (view.shortDescription !== config.shortDescription) {
    metadata.push({ field: 'shortDescription', expected: config.shortDescription, actual: view.shortDescription });
  }
  if (view.readme !== config.readme) {
    metadata.push({ field: 'readme', expected: config.readme, actual: view.readme });
  }
  if (view.public !== config.public) {
    metadata.push({ field: 'public', expected: config.public, actual: view.public });
  }

  const actualFieldByName = new Map(fields.fields.map((field) => [field.name, field]));
  const fieldCatalogMismatches: FieldCatalogDriftEntry[] = [];
  for (const fieldKey of configFieldKeys) {
    const expectedField = config.fieldCatalog[fieldKey];
    const actualField = actualFieldByName.get(expectedField.name);
    const actualOptions = Array.isArray(actualField?.options)
      ? actualField.options
          .map((option) => option?.name)
          .filter((value): value is string => typeof value === 'string')
      : [];
    const missingOptions = expectedField.options.filter((option) => !actualOptions.includes(option));
    const unexpectedOptions = actualOptions.filter((option) => !expectedField.options.includes(option));
    if (!actualField || missingOptions.length > 0 || unexpectedOptions.length > 0) {
      fieldCatalogMismatches.push({
        field: fieldKey,
        expectedName: expectedField.name,
        actualName: actualField?.name ?? null,
        missing: !actualField,
        missingOptions,
        unexpectedOptions,
      });
    }
  }

  const missingItems = config.items
    .filter((item) => !actualByUrl.has(item.url))
    .map((item) => item.url)
    .sort((a, b) => a.localeCompare(b));

  const extraItems = config.allowAdditionalItems
    ? []
    : items
        .filter((item) => !expectedByUrl.has(item.url))
        .map((item) => item.url)
        .sort((a, b) => a.localeCompare(b));

  const fieldMismatches: Array<{ url: string; drifts: DriftEntry[] }> = [];
  for (const expected of config.items) {
    const actual = actualByUrl.get(expected.url);
    if (!actual) {
      continue;
    }

    const drifts: DriftEntry[] = [];
    if (actual.status !== expected.status) {
      drifts.push({ field: 'status', expected: expected.status, actual: actual.status });
    }
    if (actual.program !== expected.program) {
      drifts.push({ field: 'program', expected: expected.program, actual: actual.program });
    }
    if (actual.phase !== expected.phase) {
      drifts.push({ field: 'phase', expected: expected.phase, actual: actual.phase });
    }
    if (actual.environmentClass !== expected.environmentClass) {
      drifts.push({
        field: 'environmentClass',
        expected: expected.environmentClass,
        actual: actual.environmentClass,
      });
    }
    if (actual.blockingSignal !== expected.blockingSignal) {
      drifts.push({ field: 'blockingSignal', expected: expected.blockingSignal, actual: actual.blockingSignal });
    }
    if (actual.evidenceState !== expected.evidenceState) {
      drifts.push({ field: 'evidenceState', expected: expected.evidenceState, actual: actual.evidenceState });
    }
    if (actual.portfolioTrack !== expected.portfolioTrack) {
      drifts.push({ field: 'portfolioTrack', expected: expected.portfolioTrack, actual: actual.portfolioTrack });
    }

    if (drifts.length > 0) {
      fieldMismatches.push({ url: expected.url, drifts });
    }
  }

  const actualRepositories = [...new Set(items.map((item) => item.repository).filter((value): value is string => Boolean(value)))].sort();
  const missingRepositories = config.repositories
    .filter((repository) => !actualRepositories.includes(repository))
    .sort((a, b) => a.localeCompare(b));
  const unexpectedRepositories = actualRepositories
    .filter((repository) => !config.repositories.includes(repository))
    .sort((a, b) => a.localeCompare(b));

  return {
    ok:
      metadata.length === 0 &&
      fieldCatalogMismatches.length === 0 &&
      missingItems.length === 0 &&
      extraItems.length === 0 &&
      fieldMismatches.length === 0 &&
      missingRepositories.length === 0 &&
      unexpectedRepositories.length === 0,
    metadata,
    fieldCatalogMismatches,
    missingItems,
    extraItems,
    fieldMismatches,
    missingRepositories,
    unexpectedRepositories,
  };
}

function loadProjectContext(args: Args, config: PortfolioConfig): ProjectContext {
  const owner = args.owner ?? config.owner;
  const number = args.number ?? config.number;
  const view = loadJsonInput(
    args.view_file,
    viewSchema,
    ['project', 'view', String(number), '--owner', owner, '--format', 'json'],
  );
  const fields = loadJsonInput(
    args.fields_file,
    fieldsSchema,
    ['project', 'field-list', String(number), '--owner', owner, '--format', 'json'],
  );
  const itemList = loadJsonInput(
    args.item_file,
    itemListSchema,
    ['project', 'item-list', String(number), '--owner', owner, '--limit', '100', '--format', 'json'],
  );

  const fieldNames = buildFieldNameMap(config);
  const normalizedItems = itemList.items
    .map((item) => normalizeItem(item, fieldNames))
    .sort((a, b) => a.url.localeCompare(b.url));

  return {
    view,
    fields,
    itemList,
    normalizedItems,
  };
}

function buildParser(): ArgumentParser {
  const parser = new ArgumentParser({
    description: 'Snapshot/check the compare-vi-cli-action portfolio GitHub Project, or deterministically apply project fields.',
  });

  parser.add_argument('mode', {
    choices: ['snapshot', 'check', 'apply'],
    help: 'Whether to snapshot the board, fail on drift, or add/apply project fields to an issue or PR URL.',
  });
  parser.add_argument('--config', {
    required: false,
    help: 'Path to the source-controlled project portfolio config JSON.',
  });
  parser.add_argument('--out', {
    required: false,
    help: 'Path for the output report JSON.',
  });
  parser.add_argument('--owner', {
    required: false,
    help: 'Project owner login override.',
  });
  parser.add_argument('--number', {
    required: false,
    type: 'int',
    help: 'Project number override.',
  });
  parser.add_argument('--view-file', {
    required: false,
    help: 'Optional path to a captured gh project view JSON payload.',
  });
  parser.add_argument('--fields-file', {
    required: false,
    help: 'Optional path to a captured gh project field-list JSON payload.',
  });
  parser.add_argument('--item-file', {
    required: false,
    help: 'Optional path to a captured gh project item-list JSON payload.',
  });
  parser.add_argument('--url', {
    required: false,
    help: 'GitHub issue or pull request URL to add/apply inside the project.',
  });
  parser.add_argument('--use-config', {
    action: 'store_true',
    help: 'Seed unspecified field values from the tracked config item that matches --url.',
  });
  parser.add_argument('--dry-run', {
    action: 'store_true',
    help: 'Resolve the add/apply plan and write a report without mutating GitHub.',
  });
  parser.add_argument('--status', {
    required: false,
    help: 'Explicit Status option to apply.',
  });
  parser.add_argument('--program', {
    required: false,
    help: 'Explicit Program option to apply.',
  });
  parser.add_argument('--phase', {
    required: false,
    help: 'Explicit Phase option to apply.',
  });
  parser.add_argument('--environment-class', {
    required: false,
    help: 'Explicit Environment Class option to apply.',
  });
  parser.add_argument('--blocking-signal', {
    required: false,
    help: 'Explicit Blocking Signal option to apply.',
  });
  parser.add_argument('--evidence-state', {
    required: false,
    help: 'Explicit Evidence State option to apply.',
  });
  parser.add_argument('--portfolio-track', {
    required: false,
    help: 'Explicit Portfolio Track option to apply.',
  });
  return parser;
}

function main(): void {
  const parser = buildParser();
  const args = parser.parse_args() as Args;
  const configPath = resolvePath(args.config ?? 'tools/priority/project-portfolio.json');
  if (!existsSync(configPath)) {
    throw new Error(`Project portfolio config not found: ${configPath}`);
  }

  const config = configSchema.parse(readJsonFile<unknown>(configPath));
  const owner = args.owner ?? config.owner;
  const number = args.number ?? config.number;
  const context = loadProjectContext(args, config);

  if (args.mode === 'apply') {
    if (!args.url) {
      throw new Error('Apply mode requires --url <issue-or-pr-url>.');
    }

    const targetUrl = normalizeGitHubUrl(args.url);
    const requestedFields = resolveRequestedApplyFields(args, config, targetUrl);
    const liveFields = resolveLiveFields(config, context.fields);
    const resolvedFieldUpdates = resolveApplyFieldUpdates(requestedFields, liveFields);
    const dryRun = Boolean(args.dry_run);
    const target = resolveApplyTarget(context.view, context.normalizedItems, targetUrl, dryRun);
    const projectedItemSnapshot = buildProjectedItemSnapshot(
      target.resource,
      target.existingItem,
      target.itemId,
      resolvedFieldUpdates,
    );

    if (!dryRun) {
      if (!target.itemId) {
        throw new Error(`Project item id could not be resolved for ${targetUrl}.`);
      }

      for (const fieldUpdate of resolvedFieldUpdates) {
        updateProjectFieldValue(context.view.id, target.itemId, fieldUpdate.fieldId, fieldUpdate.optionId);
      }
    }

    const verification = dryRun || !target.itemId
      ? {
          ok: true,
          attempts: 0,
          delayMs: 0,
          fields: resolvedFieldUpdates.map((fieldUpdate) => ({
            key: fieldUpdate.key,
            fieldName: fieldUpdate.fieldName,
            expectedValue: fieldUpdate.value,
            expectedOptionId: fieldUpdate.optionId,
            actualValue: null,
            actualOptionId: null,
            ok: false,
          })),
          skipped: true,
        }
      : {
          ...verifyAppliedFields(context.view.id, target.itemId, resolvedFieldUpdates),
          skipped: false,
        };
    const observedItemSnapshot = dryRun || !target.itemId
      ? null
      : reloadObservedItemSnapshot(args, config, target.itemId, target.resource.url);
    const boardContext = buildBoardContext(observedItemSnapshot ?? projectedItemSnapshot, target.resource);

    const report = {
      schema: applyReportSchemaId,
      generatedAt: new Date().toISOString(),
      mode: args.mode,
      configPath,
      dryRun,
      project: {
        owner,
        number,
        id: context.view.id,
        title: context.view.title,
        url: context.view.url,
      },
      target: {
        url: target.resource.url,
        title: target.resource.title ?? null,
        contentType: target.resource.__typename,
        repository: target.resource.repository?.nameWithOwner ?? null,
        contentId: target.resource.id,
        existingItemId: target.existingItem?.id ?? null,
        itemId: target.itemId,
        existed: Boolean(target.existingItem),
        added: target.added,
        wouldAdd: target.wouldAdd,
        existingItemSnapshot: target.existingItem,
        projectedItemSnapshot,
        observedItemSnapshot,
        boardContext,
      },
      appliedFields: resolvedFieldUpdates.map((fieldUpdate) => ({
        key: fieldUpdate.key,
        source: fieldUpdate.source,
        value: fieldUpdate.value,
        fieldId: fieldUpdate.fieldId,
        fieldName: fieldUpdate.fieldName,
        optionId: fieldUpdate.optionId,
        applied: !dryRun,
      })),
      verification,
    };

    const outPath = resolvePath(args.out ?? 'tests/results/_agent/project/portfolio-apply-report.json');
    writeJsonFile(outPath, report);

    const actionLabel = dryRun ? '[info]' : '[apply]';
    // eslint-disable-next-line no-console
    console.log(`${actionLabel} Project ${owner}#${number} apply report written to ${outPath}`);
    // eslint-disable-next-line no-console
    console.log(
      `${actionLabel} Target=${target.resource.url} item=${target.itemId ?? 'pending-add'} fields=${resolvedFieldUpdates.length} added=${target.added ? 'yes' : target.wouldAdd ? 'planned' : 'no'}`,
    );
    if (!dryRun && !verification.ok) {
      const mismatches = verification.fields
        .filter((fieldState) => !fieldState.ok)
        .map((fieldState) => `${fieldState.fieldName}: expected '${fieldState.expectedValue}', actual '${fieldState.actualValue ?? 'null'}'`)
        .join('; ');
      throw new Error(`Applied project fields did not verify after ${verification.attempts} attempt(s): ${mismatches}`);
    }
    return;
  }

  const drift = compareProject(config, context.view, context.fields, context.normalizedItems);
  const report = {
    schema: snapshotReportSchemaId,
    generatedAt: new Date().toISOString(),
    mode: args.mode,
    configPath,
    project: {
      owner,
      number,
      id: context.view.id,
      title: context.view.title,
      shortDescription: context.view.shortDescription,
      public: context.view.public,
      url: context.view.url,
      itemCount: context.itemList.totalCount,
      fieldCount: context.fields.totalCount,
      repositories: [...new Set(context.normalizedItems.map((item) => item.repository).filter((value): value is string => Boolean(value)))].sort(),
    },
    fields: context.fields.fields
      .map((field) => ({ id: field.id, name: field.name, type: field.type }))
      .sort((a, b) => a.name.localeCompare(b.name)),
    items: context.normalizedItems,
    drift,
  };

  const outPath = resolvePath(args.out ?? 'tests/results/_agent/project/portfolio-snapshot.json');
  writeJsonFile(outPath, report);

  const statusLabel = drift.ok ? '[info]' : '[warn]';
  // eslint-disable-next-line no-console
  console.log(`${statusLabel} Project ${owner}#${number} snapshot written to ${outPath}`);
  // eslint-disable-next-line no-console
  console.log(
    `${statusLabel} Items expected=${config.items.length} actual=${context.normalizedItems.length} drift=${drift.ok ? 'none' : 'present'}`,
  );

  if (args.mode === 'check' && !drift.ok) {
    throw new Error('Project portfolio drift detected. Review the JSON report for details.');
  }
}

main();
