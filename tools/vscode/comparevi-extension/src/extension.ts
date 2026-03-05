import * as vscode from "vscode";
import * as path from "path";
import * as fs from "fs";
import { TextDecoder } from "util";
import { spawn, spawnSync, ChildProcess } from "child_process";
import * as os from "os";

const TASK_BUILD = "Build CompareVI CLI (Release)";
const TASK_PARSE = "Parse CLI Compare Outcome (.NET)";
const TASK_AUTO_PUSH = "Integration (Standing Priority): Auto Push + Start + Watch";
const TASK_WATCH = "Integration (Standing Priority): Watch existing run";
const LVCOMPARE_SCRIPT = "tools/Invoke-LVCompare.ps1";
const DEFAULT_MANUAL_OUTPUT = "tests/results/manual-vi2-compare";
const SOURCE_STATE_KEY = "comparevi.manualSources";

const utf8Decoder = new TextDecoder("utf-8");

interface ArtifactDefinition {
    id: string;
    label: string;
    relativePath: string;
    summary?: boolean;
}

const artifactDefinitions: ArtifactDefinition[] = [
    {
        id: "queueSummary",
        label: "Queue Summary (compare-cli)",
        relativePath: "tests/results/compare-cli/queue-summary.json",
        summary: true
    },
    {
        id: "compareOutcome",
        label: "Compare Outcome (compare-cli)",
        relativePath: "tests/results/compare-cli/compare-outcome.json",
        summary: true
    },
    {
        id: "manualCapture",
        label: "LVCompare Capture (manual)",
        relativePath: "tests/results/manual-vi2-compare/lvcompare-capture.json",
        summary: true
    },
    {
        id: "manualReport",
        label: "LVCompare Report (manual)",
        relativePath: "tests/results/manual-vi2-compare/compare-report.html"
    },
    {
        id: "sessionIndex",
        label: "Session Index",
        relativePath: "tests/results/session-index.json"
    },
    {
        id: "phaseVars",
        label: "Phase Vars Manifest",
        relativePath: "tests/results/_phase/vars.json"
    }
];

interface ManualSourceEntry {
    id: string;
    ref: string;
    path?: string;
}

interface ManualProfile {
    name: string;
    year?: string;
    bits?: string;
    vis?: ManualSourceEntry[];
    defaultBase?: string;
    defaultHead?: string;
    baseVi?: string;
    headVi?: string;
    outputDir?: string;
    flags?: string[];
    labviewExePath?: string;
}

interface SourceSelectionCache {
    id: string;
    path: string;
}

type ManualSourceState = Record<string, {
    base?: SourceSelectionCache;
    head?: SourceSelectionCache;
}>;

let manualSourceState: ManualSourceState | undefined;
let manualOutputChannel: vscode.OutputChannel | undefined;

class ArtifactItem extends vscode.TreeItem {
    constructor(
        public readonly definition: ArtifactDefinition,
        public readonly resourceUri: vscode.Uri
    ) {
        super(definition.label, vscode.TreeItemCollapsibleState.None);
        this.tooltip = resourceUri.fsPath;
        this.command = {
            command: "comparevi.openArtifact",
            title: "CompareVI: Open Artifact",
            arguments: [this]
        };
        const ext = path.extname(resourceUri.fsPath).toLowerCase();
        this.contextValue =
            definition.summary && ext === ".json"
                ? "compareviJsonArtifact"
                : "compareviArtifact";
    }
}

class ArtifactTreeProvider implements vscode.TreeDataProvider<ArtifactItem> {
    private readonly _onDidChangeTreeData = new vscode.EventEmitter<void>();
    readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

    constructor(private workspaceFolder: vscode.WorkspaceFolder | undefined) {}

    setWorkspaceFolder(folder: vscode.WorkspaceFolder | undefined) {
        this.workspaceFolder = folder;
        this.refresh();
    }

    getWorkspaceFolder(): vscode.WorkspaceFolder | undefined {
        return this.workspaceFolder;
    }

    refresh(): void {
        this._onDidChangeTreeData.fire();
    }

    getTreeItem(element: ArtifactItem): vscode.TreeItem {
        return element;
    }

    async getChildren(element?: ArtifactItem): Promise<ArtifactItem[]> {
        if (element) {
            return [];
        }
        const folder = this.workspaceFolder;
        if (!folder) {
            return [];
        }
        const items: ArtifactItem[] = [];
        for (const def of artifactDefinitions) {
            const uri = vscode.Uri.joinPath(folder.uri, ...def.relativePath.split("/"));
            try {
                await vscode.workspace.fs.stat(uri);
                items.push(new ArtifactItem(def, uri));
            } catch {
                // Artifact not present yet
            }
        }
        return items;
    }

    async pickArtifact(filter?: (def: ArtifactDefinition) => boolean): Promise<ArtifactItem | undefined> {
        const roots = await this.getChildren();
        const filtered = filter ? roots.filter(item => filter(item.definition)) : roots;
        if (filtered.length === 0) {
            vscode.window.showInformationMessage("No CompareVI artifacts found yet.");
            return undefined;
        }
        if (filtered.length === 1) {
            return filtered[0];
        }
        const pick = await vscode.window.showQuickPick(
            filtered.map(item => ({
                label: item.definition.label,
                description: item.resourceUri.fsPath
            })),
            { placeHolder: "Select CompareVI artifact" }
        );
        if (!pick) {
            return undefined;
        }
        return filtered.find(item => item.definition.label === pick.label);
    }
}

let workspaceMemento: vscode.Memento | undefined;

function getManualSourceState(): ManualSourceState {
    if (!manualSourceState) {
        const stored = workspaceMemento?.get<ManualSourceState>(SOURCE_STATE_KEY);
        manualSourceState = stored ?? {};
    }
    return manualSourceState;
}

async function updateManualSourceState(
    profileName: string | undefined,
    role: "base" | "head",
    entryId: string,
    viPath: string
) {
    const key = profileName && profileName.trim() ? profileName : "(unnamed)";
    const state = getManualSourceState();
    const existing = state[key] ?? {};
    const next = { ...existing, [role]: { id: entryId, path: viPath } };
    const updated = { ...state, [key]: next };
    manualSourceState = updated;
    if (workspaceMemento) {
        await workspaceMemento.update(SOURCE_STATE_KEY, updated);
    }
}

function resolveWorkspacePath(raw: string | undefined, repoRoot: string): string | undefined {
    if (!raw || !raw.trim()) {
        return undefined;
    }
    const trimmed = raw.trim();
    if (trimmed.includes("${workspaceFolder}")) {
        return trimmed.replace("${workspaceFolder}", repoRoot);
    }
    if (path.isAbsolute(trimmed)) {
        return trimmed;
    }
    return path.join(repoRoot, trimmed);
}

function resolveLabVIEWPath(year: string, bits: string): string {
    const pf64 = process.env.ProgramW6432 || process.env.ProgramFiles || "C:\\Program Files";
    const pf86 = process.env["ProgramFiles(x86)"] || pf64;
    const parent = bits === "32" ? pf86 : pf64;
    return path.join(parent, "National Instruments", `LabVIEW ${year}`, "LabVIEW.exe");
}

function runGitCommand(
    repoRoot: string,
    args: string[],
    encoding: BufferEncoding | "buffer" = "utf8"
): string | Buffer {
    const result = spawnSync("git", args, {
        cwd: repoRoot,
        encoding
    });
    if (result.status !== 0) {
        const stderr = typeof result.stderr === "string" ? result.stderr : result.stderr?.toString("utf8");
        throw new Error(stderr?.trim() || `git ${args.join(" ")} failed`);
    }
    return result.stdout;
}

function getCommitInfo(repoRoot: string, entry: ManualSourceEntry) {
    const stdout = runGitCommand(repoRoot, [
        "show",
        "-s",
        "--format=%H%n%h%n%ad%n%s",
        "--date=iso-strict",
        entry.ref
    ]) as string;
    const [hash = entry.ref, shortHash = entry.ref, date = "", subject = ""] = stdout.trim().split("\n");
    return { hash, shortHash, date, subject };
}

function listVisAtCommit(repoRoot: string, ref: string): string[] {
    const stdout = runGitCommand(repoRoot, [
        "ls-tree",
        "--full-tree",
        "-r",
        "--name-only",
        ref
    ]) as string;
    return stdout
        .split("\n")
        .map(line => line.trim())
        .filter(line => line.toLowerCase().endsWith(".vi"))
        .filter(Boolean);
}

async function readManualProfiles(
    config: vscode.WorkspaceConfiguration,
    repoRoot: string
): Promise<{ profilePath: string; profiles: ManualProfile[] }> {
    const profilePathSetting = config.get<string>("manualProfilePath", "tools/comparevi.profiles.json");
    const resolved = resolveWorkspacePath(profilePathSetting, repoRoot) ?? path.join(repoRoot, "tools/comparevi.profiles.json");
    if (!fs.existsSync(resolved)) {
        return { profilePath: resolved, profiles: [] };
    }
    try {
        const contents = fs.readFileSync(resolved, "utf8");
        const parsed = JSON.parse(contents);
        const profiles: ManualProfile[] = Array.isArray(parsed)
            ? parsed
            : Array.isArray(parsed?.profiles)
            ? parsed.profiles
            : [];
        return { profilePath: resolved, profiles };
    } catch (error) {
        vscode.window.showErrorMessage(
            `Failed to parse manual profile file (${resolved}): ${(error as Error).message}`
        );
        return { profilePath: resolved, profiles: [] };
    }
}

function findVisEntry(profile: ManualProfile, id: string | undefined): ManualSourceEntry | undefined {
    if (!id || !Array.isArray(profile.vis)) {
        return undefined;
    }
    return profile.vis.find(entry => entry.id === id);
}

function resolveOutputDir(profile: ManualProfile, repoRoot: string): string {
    const setting = profile.outputDir || DEFAULT_MANUAL_OUTPUT;
    return resolveWorkspacePath(setting, repoRoot) ?? path.join(repoRoot, DEFAULT_MANUAL_OUTPUT);
}

async function pickManualProfile(
    config: vscode.WorkspaceConfiguration,
    repoRoot: string
): Promise<ManualProfile | undefined> {
    const result = await readManualProfiles(config, repoRoot);
    const profiles = result.profiles;
    const profilePath = result.profilePath;
    if (!profiles.length) {
        const choice = await vscode.window.showWarningMessage(
            `No manual profiles defined at ${profilePath}. Create sample profiles?`,
            { modal: true },
            "Create",
            "Cancel"
        );
        if (choice === "Create") {
            await createSampleProfiles(profilePath);
            return pickManualProfile(config, repoRoot);
        }
        return undefined;
    }
    if (profiles.length === 1) {
        return profiles[0];
    }
    const pick = await vscode.window.showQuickPick(
        profiles.map(p => ({
            label: p.name || "(unnamed)",
            description: `${p.year ?? "?"}-${p.bits ?? "?"}`,
            profile: p
        })),
        { placeHolder: "Select CompareVI profile" }
    );
    return pick?.profile;
}

async function selectCommitEntry(
    profile: ManualProfile,
    role: "base" | "head",
    repoRoot: string,
    config: vscode.WorkspaceConfiguration,
    forcePrompt = false
) {
    const entries = Array.isArray(profile.vis) ? profile.vis : [];
    if (!entries.length) {
        throw new Error("Profile does not declare commit-based sources.");
    }
    const showPicker = forcePrompt || config.get<boolean>("showSourcePicker", true);
    const state = getManualSourceState();
    const key = profile.name && profile.name.trim() ? profile.name : "(unnamed)";
    const remembered = state[key]?.[role];
    const defaultId = remembered?.id
        || (role === "base" ? profile.defaultBase : profile.defaultHead)
        || entries[0]!.id;

    const items = entries.map(entry => {
        const info = getCommitInfo(repoRoot, entry);
        return {
            label: entry.id,
            description: `${info.shortHash} ${info.subject}`.trim(),
            detail: info.date,
            entry,
            info
        };
    });

    if (!items.length) {
        throw new Error("Profile does not declare commit entries.");
    }

    const defaultItem = items.find(item => item.entry.id === defaultId) ?? items[0]!;
    let chosenItem = defaultItem;
    if (showPicker && items.length > 1) {
        const pick = await vscode.window.showQuickPick<vscode.QuickPickItem>(
            items.map(item => ({
                label: item.label,
                description: item.description,
                detail: item.detail
            })),
            {
                placeHolder: `Select ${role} commit for ${profile.name}`
            }
        );
        if (pick) {
            const match = items.find(item => item.label === pick.label);
            if (match) {
                chosenItem = match;
            }
        }
    }

    const viCandidates = listVisAtCommit(repoRoot, chosenItem.entry.ref);
    if (!viCandidates.length) {
        throw new Error(`No VI files found in commit ${chosenItem.entry.ref}.`);
    }

    let viPath = chosenItem.entry.path ?? remembered?.path ?? viCandidates[0]!;
    if (showPicker || !chosenItem.entry.path) {
        const pick = await vscode.window.showQuickPick(
            viCandidates,
            {
                placeHolder: `Select VI for ${role} (${chosenItem.entry.ref})`
            }
        );
        if (pick) {
            viPath = pick;
        }
    }
    await updateManualSourceState(profile.name, role, chosenItem.entry.id, viPath);
    return { entry: chosenItem.entry, commit: chosenItem.info, viPath };
}

async function prepareCommitSources(
    profile: ManualProfile,
    config: vscode.WorkspaceConfiguration,
    repoRoot: string
) {
    const keepTemp = config.get<boolean>("keepTempVi", false);
    const tempDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "comparevi-"));
    let baseSelection: any | undefined;
    let headSelection: any | undefined;
    try {
        baseSelection = await selectCommitEntry(profile, "base", repoRoot, config);
        headSelection = await selectCommitEntry(profile, "head", repoRoot, config);
        const basePath = extractFileAtCommit(repoRoot, baseSelection.entry.ref, baseSelection.viPath, path.join(tempDir, "base.vi"));
        const headPath = extractFileAtCommit(repoRoot, headSelection.entry.ref, headSelection.viPath, path.join(tempDir, "head.vi"));
        return {
            tempDir,
            base: {
                tempPath: basePath,
                id: baseSelection.entry.id,
                ref: baseSelection.entry.ref,
                viPath: baseSelection.viPath,
                commit: baseSelection.commit
            },
            head: {
                tempPath: headPath,
                id: headSelection.entry.id,
                ref: headSelection.entry.ref,
                viPath: headSelection.viPath,
                commit: headSelection.commit
            },
            keepTemp
        };
    } catch (error) {
        await cleanupTempDir(tempDir, keepTemp);
        throw error;
    }
}

function extractFileAtCommit(
    repoRoot: string,
    ref: string,
    filePath: string,
    destinationPath: string
) {
    const output = runGitCommand(repoRoot, ["show", `${ref}:${filePath}`], "buffer") as Buffer;
    fs.mkdirSync(path.dirname(destinationPath), { recursive: true });
    fs.writeFileSync(destinationPath, output);
    return destinationPath;
}

async function cleanupTempDir(tempDir: string, keep: boolean) {
    if (keep) {
        return;
    }
    try {
        await fs.promises.rm(tempDir, { recursive: true, force: true });
    } catch {
        // ignore cleanup failures
    }
}

async function runLvCompare(
    repoRoot: string,
    baseVi: string,
    headVi: string,
    outputDir: string,
    flags: string[] | undefined,
    channel: vscode.OutputChannel
): Promise<number> {
    const scriptPath = path.join(repoRoot, LVCOMPARE_SCRIPT);
    const args = [
        "-NoLogo",
        "-NoProfile",
        "-File",
        scriptPath,
        "-BaseVi",
        baseVi,
        "-HeadVi",
        headVi,
        "-OutputDir",
        outputDir,
        "-RenderReport"
    ];
    if (flags && flags.length) {
        args.push("-Flags", ...flags);
    }

    return new Promise<number>((resolve, reject) => {
        const spawnWith = (command: string) => spawn(command, args, { cwd: repoRoot });
        let child = spawnWith(process.platform === "win32" ? "pwsh" : "pwsh");
        let resolved = false;
        let attemptedFallback = false;

        const attachListeners = (proc: ChildProcess) => {
            proc.stdout?.on("data", data => channel.append(data.toString()));
            proc.stderr?.on("data", data => channel.append(data.toString()));

            proc.on("error", err => {
                if (!attemptedFallback && process.platform === "win32") {
                    attemptedFallback = true;
                    child = spawnWith("powershell");
                    attachListeners(child);
                } else if (!resolved) {
                    resolved = true;
                    reject(err);
                }
            });

            proc.on("close", code => {
                if (!resolved) {
                    resolved = true;
                    resolve(code ?? 0);
                }
            });
        };

        attachListeners(child);
    });
}

async function runProfileWithProfile(
    profile: ManualProfile,
    config: vscode.WorkspaceConfiguration,
    repoRoot: string,
    refreshArtifacts: () => void,
    origin: "command" | "tree",
    onStateChanged?: () => void
) {
    if (!manualOutputChannel) {
        manualOutputChannel = vscode.window.createOutputChannel("CompareVI Manual");
    }
    const channel = manualOutputChannel;

    const outputDir = resolveOutputDir(profile, repoRoot);
    fs.mkdirSync(outputDir, { recursive: true });

    const year = String(profile.year || config.get("labview.year", "2025"));
    const bits = String(profile.bits || config.get("labview.bits", "64"));
    const labviewExePath = profile.labviewExePath || resolveLabVIEWPath(year, bits);

    if (!fs.existsSync(labviewExePath)) {
        const choice = await vscode.window.showWarningMessage(
            `LabVIEW executable not found at ${labviewExePath}. Continue anyway?`,
            { modal: true },
            "Continue",
            "Cancel"
        );
        if (choice !== "Continue") {
            return;
        }
    }

    const flags = Array.isArray(profile.flags) ? profile.flags : [];

    channel.appendLine("");
    channel.appendLine(`[${new Date().toISOString()}] CompareVI profile '${profile.name || "(unnamed)"}' started (${origin})`);

    if (profile.vis && profile.vis.length) {
        const { tempDir, base, head, keepTemp } = await prepareCommitSources(profile, config, repoRoot);
        try {
            const exitCode = await runLvCompare(repoRoot, base.tempPath, head.tempPath, outputDir, flags, channel);
            await cleanupTempDir(tempDir, keepTemp);
            refreshArtifacts();
            onStateChanged?.();

            await showManualSummary(outputDir, config, { base, head, exitCode });
        } catch (error) {
            await cleanupTempDir(tempDir, config.get<boolean>("keepTempVi", false));
            throw error;
        }
        return;
    }

    if (!profile.baseVi || !profile.headVi) {
        throw new Error("Profile is missing vis entries or base/head paths.");
    }

    const baseVi = resolveWorkspacePath(profile.baseVi, repoRoot);
    const headVi = resolveWorkspacePath(profile.headVi, repoRoot);
    if (!baseVi || !headVi) {
        throw new Error("Unable to resolve base/head VI paths.");
    }

    const exitCode = await runLvCompare(repoRoot, baseVi, headVi, outputDir, flags, channel);
    refreshArtifacts();
    onStateChanged?.();
    await showManualSummary(outputDir, config, {
        exitCode,
        base: { id: "base", ref: "workspace", viPath: profile.baseVi, tempPath: baseVi },
        head: { id: "head", ref: "workspace", viPath: profile.headVi, tempPath: headVi }
    });
}

async function showManualSummary(
    outputDir: string,
    config: vscode.WorkspaceConfiguration,
    details: {
        exitCode: number;
        base: { id: string; ref: string; viPath: string; tempPath: string; commit?: any };
        head: { id: string; ref: string; viPath: string; tempPath: string; commit?: any };
    }
) {
    const capturePath = path.join(outputDir, "lvcompare-capture.json");
    const reportPath = path.join(outputDir, "compare-report.html");
    const buttons: string[] = [];
    const captureExists = fs.existsSync(capturePath);
    const reportExists = fs.existsSync(reportPath);

    if (reportExists) {
        buttons.push("Open Report");
    }
    if (captureExists) {
        buttons.push("Open Capture");
    }

    const message = `LVCompare completed (exit ${details.exitCode}). Base: ${details.base.ref} (${details.base.viPath}), Head: ${details.head.ref} (${details.head.viPath}).`;
    const selection = await vscode.window.showInformationMessage(message, ...buttons);
    if (selection === "Open Report" && reportExists) {
        await vscode.commands.executeCommand("vscode.open", vscode.Uri.file(reportPath));
    } else if (selection === "Open Capture" && captureExists) {
        await vscode.commands.executeCommand("vscode.open", vscode.Uri.file(capturePath));
    }

    const autoOpenReport = config.get<boolean>("autoOpenReportOnDiff", true);
    if (autoOpenReport && reportExists) {
        await vscode.commands.executeCommand("vscode.open", vscode.Uri.file(reportPath));
    }
}

class ManualProfileTreeItem extends vscode.TreeItem {
    constructor(public readonly profile: ManualProfile, private readonly repoRoot: string) {
        super(profile.name || "(unnamed)", vscode.TreeItemCollapsibleState.None);
        this.contextValue = "compareviManualProfile";
        this.command = {
            command: "comparevi.manual.runProfile",
            title: "CompareVI Manual: Run Profile",
            arguments: [this]
        };
        const summary = this.buildSummary();
        this.description = summary.description;
        this.tooltip = summary.tooltip;
        this.iconPath = new vscode.ThemeIcon(profile.vis && profile.vis.length ? "git-compare" : "symbol-file");
    }

    private buildSummary(): { description: string; tooltip: string } {
        const key = this.profile.name && this.profile.name.trim() ? this.profile.name : "(unnamed)";
        const state = getManualSourceState()[key];
        const baseInfo = this.buildSourceInfo("base", state?.base);
        const headInfo = this.buildSourceInfo("head", state?.head);
        const description = `${baseInfo.label} → ${headInfo.label}`;
        const tooltip = [
            this.profile.name || "(unnamed)",
            `Base: ${baseInfo.tooltip}`,
            `Head: ${headInfo.tooltip}`,
            `Output Dir: ${resolveOutputDir(this.profile, this.repoRoot)}`
        ].join("\n");
        return { description, tooltip };
    }

    private buildSourceInfo(
        role: "base" | "head",
        cached?: SourceSelectionCache
    ): { label: string; tooltip: string } {
        if (!this.profile.vis || this.profile.vis.length === 0) {
            const pathValue = role === "base" ? this.profile.baseVi : this.profile.headVi;
            const tooltip = pathValue ?? "Workspace VI";
            return { label: "workspace", tooltip };
        }

        const entries = this.profile.vis as ManualSourceEntry[];
        const fallbackId = role === "base" ? this.profile.defaultBase : this.profile.defaultHead;
        const defaultEntryId = entries[0]?.id;
        const entry = findVisEntry(this.profile, cached?.id ?? fallbackId ?? defaultEntryId);
        const labelId = cached?.id ?? entry?.id ?? fallbackId ?? "?";

        if (!entry) {
            const tooltip = cached?.path ? `${labelId} (VI: ${cached.path})` : labelId;
            return { label: labelId, tooltip };
        }

        let label = labelId;
        let tooltip = labelId;
        try {
            const info = getCommitInfo(this.repoRoot, entry);
            label = `${entry.id} (${info.shortHash})`;
            const parts = [
                `${entry.id}`,
                `Commit: ${info.shortHash} ${info.subject}`
            ];
            if (info.date) {
                parts.push(`Date: ${info.date}`);
            }
            tooltip = parts.join("\n");
        } catch {
            tooltip = entry.id;
        }

        const pathValue = cached?.path ?? entry.path;
        if (pathValue) {
            tooltip += `\nVI: ${pathValue}`;
        }

        return { label, tooltip };
    }
}

class ManualProfilesProvider implements vscode.TreeDataProvider<ManualProfileTreeItem>, vscode.Disposable {
    private readonly _onDidChangeTreeData = new vscode.EventEmitter<ManualProfileTreeItem | undefined>();
    readonly onDidChangeTreeData = this._onDidChangeTreeData.event;

    private profiles: ManualProfile[] = [];
    private profilePath?: string;
    private watcher?: vscode.FileSystemWatcher;
    private readonly disposables: vscode.Disposable[] = [];

    constructor(private readonly repoRoot: string) {
        void this.refreshProfiles();
        this.disposables.push(
            vscode.workspace.onDidChangeConfiguration(e => {
                if (e.affectsConfiguration("comparevi.manualProfilePath")) {
                    void this.refreshProfiles();
                }
            })
        );
    }

    dispose(): void {
        this.watcher?.dispose();
        this.disposables.forEach(d => d.dispose());
    }

    async refreshProfiles() {
        const config = getConfiguration();
        const result = await readManualProfiles(config, this.repoRoot);
        this.profilePath = result.profilePath;
        if (!fs.existsSync(result.profilePath)) {
            await createSampleProfiles(result.profilePath);
            const next = await readManualProfiles(config, this.repoRoot);
            this.profilePath = next.profilePath;
            this.profiles = next.profiles;
        } else {
            this.profiles = result.profiles;
        }
        this.resetWatcher();
        this._onDidChangeTreeData.fire(undefined);
    }

    notifyStateChanged() {
        this._onDidChangeTreeData.fire(undefined);
    }

    getTreeItem(element: ManualProfileTreeItem): vscode.TreeItem {
        return element;
    }

    async getChildren(): Promise<ManualProfileTreeItem[]> {
        return this.profiles.map(profile => new ManualProfileTreeItem(profile, this.repoRoot));
    }

    private resetWatcher() {
        this.watcher?.dispose();
        if (!this.profilePath) {
            return;
        }
        this.watcher = vscode.workspace.createFileSystemWatcher(this.profilePath);
        this.disposables.push(this.watcher);
        this.watcher.onDidChange(() => void this.refreshProfiles(), undefined, this.disposables);
        this.watcher.onDidCreate(() => void this.refreshProfiles(), undefined, this.disposables);
        this.watcher.onDidDelete(async () => {
            if (this.profilePath) {
                await createSampleProfiles(this.profilePath);
            }
            await this.refreshProfiles();
        }, undefined, this.disposables);
    }
}

async function createSampleProfiles(targetPath: string) {
    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    const repoRoot = workspaceFolder?.uri.fsPath ?? process.cwd();
    const resolved = path.isAbsolute(targetPath)
        ? targetPath
        : path.join(repoRoot, targetPath);

    const sample = {
        profiles: [
            {
                name: "vi2-root-vs-previous",
                year: "2025",
                bits: "64",
                vis: [
                    { id: "root", ref: "HEAD", path: "VI2.vi" },
                    { id: "previous", ref: "HEAD~1", path: "VI2.vi" }
                ],
                defaultBase: "previous",
                defaultHead: "root",
                outputDir: "${workspaceFolder}/tests/results/manual-vi2-compare",
                flags: []
            }
        ]
    };

    await fs.promises.mkdir(path.dirname(resolved), { recursive: true });
    await fs.promises.writeFile(resolved, JSON.stringify(sample, null, 2), "utf8");
    vscode.window.showInformationMessage(`Created sample CompareVI profile at ${resolved}`);
}

interface DiagnosticState {
    lastOutcomeSignature?: string;
}

const diagnosticState: DiagnosticState = {};

async function runTask(label: string) {
    const tasks = await vscode.tasks.fetchTasks();
    const task = tasks.find(t => t.name === label);
    if (!task) {
        vscode.window.showErrorMessage(`VS Code task "${label}" not found.`);
        return;
    }
    await vscode.tasks.executeTask(task);
}

async function buildAndParse() {
    await runTask(TASK_BUILD);
    await runTask(TASK_PARSE);
}

async function runManualCompareCommand(
    repoRoot: string,
    refreshArtifacts: () => void,
    manualProvider: ManualProfilesProvider
) {
    const config = getConfiguration();
    const profile = await pickManualProfile(config, repoRoot);
    if (!profile) {
        return;
    }

    try {
        await runProfileWithProfile(
            profile,
            config,
            repoRoot,
            refreshArtifacts,
            "command",
            () => manualProvider.notifyStateChanged()
        );
    } catch (error) {
        vscode.window.showErrorMessage(
            `Manual LVCompare failed: ${(error as Error).message}`
        );
    }
}

function getConfiguration() {
    return vscode.workspace.getConfiguration("comparevi");
}

function getTokenFallbackPath(): string | undefined {
    const config = getConfiguration();
    const defaultPath = process.platform === "win32" ? "C\\\\github_token.txt" : "";
    const configured = config.get<string>("tokenFallbackPath", defaultPath);
    if (!configured || !configured.trim()) {
        return undefined;
    }
    return configured;
}

async function ensureAdminToken(): Promise<boolean> {
    if (process.env.GH_TOKEN || process.env.GITHUB_TOKEN) {
        return true;
    }
    const fallback = getTokenFallbackPath();
    if (fallback && fs.existsSync(fallback)) {
        return true;
    }
    const choice = await vscode.window.showWarningMessage(
        "GH_TOKEN/GITHUB_TOKEN not detected. Standing priority automation may fail when pushing or dispatching. Continue anyway?",
        { modal: true },
        "Continue",
        "Cancel"
    );
    return choice === "Continue";
}

async function pickStandingPriorityIssue(): Promise<string | undefined> {
    const config = getConfiguration();
    const cached = config.get<string>("standingPriorityIssue");
    const items: vscode.QuickPickItem[] = [];
    if (cached) {
        items.push({
            label: cached,
            description: "Cached standing priority issue"
        });
    }
    items.push({
        label: "Enter issue number…",
        description: "Manually enter issue number"
    });
    const choice = await vscode.window.showQuickPick(items, {
        placeHolder: "Standing priority issue"
    });
    if (!choice) {
        return undefined;
    }
    if (choice.label === "Enter issue number…") {
        const input = await vscode.window.showInputBox({
            prompt: "Enter issue number (e.g., 125)",
            validateInput: value =>
                value.match(/^\d+$/) ? undefined : "Issue number must be digits"
        });
        if (input) {
            await config.update(
                "standingPriorityIssue",
                input,
                vscode.ConfigurationTarget.Global
            );
        }
        return input;
    }
    return choice.label;
}

function escapeHtml(value: string): string {
    return value
        .replace(/&/g, "&amp;")
        .replace(/</g, "&lt;")
        .replace(/>/g, "&gt;")
        .replace(/"/g, "&quot;")
        .replace(/'/g, "&#39;");
}

function renderSummaryHTML(def: ArtifactDefinition, jsonText: string): string {
    try {
        const data = JSON.parse(jsonText);
        if (def.id === "compareOutcome" && Array.isArray(data?.cases)) {
            const rows = data.cases
                .map(
                    (c: any) =>
                        `<tr><td>${escapeHtml(String(c?.id ?? ""))}</td><td>${escapeHtml(
                            String(c?.status ?? "")
                        )}</td><td>${escapeHtml(String(c?.exit ?? ""))}</td><td>${escapeHtml(
                            String(c?.diff ?? "")
                        )}</td></tr>`
                )
                .join("");
            return `
                <h2>${escapeHtml(def.label)}</h2>
                <table>
                    <thead><tr><th>Case</th><th>Status</th><th>Exit</th><th>Diff</th></tr></thead>
                    <tbody>${rows}</tbody>
                </table>`;
        }
        if (def.id === "queueSummary" && Array.isArray(data?.cases)) {
            const rows = data.cases
                .map(
                    (c: any) =>
                        `<tr><td>${escapeHtml(String(c?.id ?? ""))}</td><td>${escapeHtml(
                            String(c?.status ?? "")
                        )}</td><td>${escapeHtml(String(c?.duration ?? ""))}</td></tr>`
                )
                .join("");
            return `
                <h2>${escapeHtml(def.label)}</h2>
                <table>
                    <thead><tr><th>Case</th><th>Status</th><th>Duration</th></tr></thead>
                    <tbody>${rows}</tbody>
                </table>`;
        }
        return `<h2>${escapeHtml(def.label)}</h2><pre>${escapeHtml(
            JSON.stringify(data, null, 2)
        )}</pre>`;
    } catch {
        return `<h2>${escapeHtml(def.label)}</h2><pre>${escapeHtml(jsonText)}</pre>`;
    }
}

async function showArtifactSummary(
    provider: ArtifactTreeProvider,
    item?: ArtifactItem
) {
    const target =
        item ?? (await provider.pickArtifact(def => Boolean(def.summary)));
    if (!target) {
        return;
    }
    if (!target.definition.summary) {
        vscode.window.showInformationMessage(
            `${target.definition.label} does not have a summary view.`
        );
        return;
    }
    try {
        const content = await vscode.workspace.fs.readFile(target.resourceUri);
        const text = utf8Decoder.decode(content);
        const panel = vscode.window.createWebviewPanel(
            "compareviArtifactSummary",
            `${target.definition.label} Summary`,
            vscode.ViewColumn.Beside,
            { enableScripts: false }
        );
        panel.webview.html = `<!DOCTYPE html>
        <html>
            <head>
                <meta charset="utf-8">
                <style>
                body { font-family: var(--vscode-font-family); padding: 16px; }
                table { border-collapse: collapse; width: 100%; }
                th, td { border: 1px solid var(--vscode-editor-foreground); padding: 4px 8px; text-align: left; }
                thead { background: var(--vscode-editor-background); }
                pre { background: var(--vscode-editor-background); padding: 12px; border-radius: 4px; overflow-x: auto; }
                </style>
            </head>
            <body>
                ${renderSummaryHTML(target.definition, text)}
            </body>
        </html>`;
    } catch (error) {
        vscode.window.showErrorMessage(
            `Failed to read artifact: ${(error as Error).message}`
        );
    }
}

async function openArtifact(
    provider: ArtifactTreeProvider,
    item?: ArtifactItem
) {
    const target = item ?? (await provider.pickArtifact());
    if (!target) {
        return;
    }
    await vscode.window.showTextDocument(target.resourceUri, { preview: true });
}

function computeOutcomeSignature(cases: any[]): string {
    return JSON.stringify(
        cases.map(c => ({
            id: c?.id,
            status: c?.status,
            exit: c?.exit,
            diff: c?.diff
        }))
    );
}

async function evaluateOutcomeDiagnostics(
    provider: ArtifactTreeProvider,
    state: DiagnosticState
) {
    const folder = provider.getWorkspaceFolder();
    if (!folder) {
        return;
    }
    const outcomeUri = vscode.Uri.joinPath(
        folder.uri,
        "tests/results/compare-cli/compare-outcome.json"
    );
    let content: Uint8Array;
    try {
        content = await vscode.workspace.fs.readFile(outcomeUri);
    } catch {
        delete state.lastOutcomeSignature;
        return;
    }
    const text = utf8Decoder.decode(content);
    let data: any;
    try {
        data = JSON.parse(text);
    } catch {
        return;
    }
    if (!Array.isArray(data?.cases)) {
        return;
    }
    const signature = computeOutcomeSignature(data.cases);
    if (signature === state.lastOutcomeSignature) {
        return;
    }
    state.lastOutcomeSignature = signature;
    const problems = data.cases.filter((c: any) => {
        const status = String(c?.status ?? "").toLowerCase();
        const exit = Number(c?.exit ?? 0);
        const diff = c?.diff;
        const statusBad = status && status !== "passed" && status !== "success";
        const exitBad = Number.isFinite(exit) && exit !== 0;
        const diffBad = diff === true || diff === "true";
        return statusBad || exitBad || diffBad;
    });
    if (problems.length > 0) {
        vscode.window.showWarningMessage(
            `CompareVI CLI outcome reports ${problems.length} non-passing case(s). Open the artifact summary for details.`,
            "Show Summary",
            "Dismiss"
        ).then(selection => {
            if (selection === "Show Summary") {
                showArtifactSummary(provider);
            }
        });
    }
}

export function activate(context: vscode.ExtensionContext) {
    workspaceMemento = context.workspaceState;
    if (!manualOutputChannel) {
        manualOutputChannel = vscode.window.createOutputChannel("CompareVI Manual");
        context.subscriptions.push(manualOutputChannel);
    }

    const workspaceFolder = vscode.workspace.workspaceFolders?.[0];
    const repoRoot = workspaceFolder?.uri.fsPath ?? process.cwd();
    const artifactProvider = new ArtifactTreeProvider(workspaceFolder);

    const treeView = vscode.window.createTreeView("compareviArtifactExplorer", {
        treeDataProvider: artifactProvider
    });
    context.subscriptions.push(treeView);

    const manualProvider = new ManualProfilesProvider(repoRoot);
    const manualTree = vscode.window.createTreeView("compareviManualProfiles", {
        treeDataProvider: manualProvider
    });
    context.subscriptions.push(manualProvider, manualTree);

    const statusBar = vscode.window.createStatusBarItem(
        vscode.StatusBarAlignment.Left,
        100
    );
    statusBar.command = "comparevi.watchStandingPriority";
    statusBar.text = "CompareVI: idle";
    statusBar.tooltip = "Run CompareVI tasks or watch standing priority runs.";
    statusBar.show();
    // Initial session-index read if present
    const initialResultsRoot = getConfiguration().get<string>("watch.resultsPath", "tests/results");
    const initialSessionIndex = resolvePreferredSessionIndexPath(repoRoot, initialResultsRoot);
    void refreshFromSessionIndex(initialSessionIndex, statusBar);

    const disposables: vscode.Disposable[] = [];

    const refreshArtifacts = () => {
        artifactProvider.refresh();
        void evaluateOutcomeDiagnostics(artifactProvider, diagnosticState);
        // Opportunistically refresh status bar from session index on any results change
        const resultsRoot = getConfiguration().get<string>("watch.resultsPath", "tests/results");
        const sessionIndex = resolvePreferredSessionIndexPath(repoRoot, resultsRoot);
        void refreshFromSessionIndex(sessionIndex, statusBar);
    };

    if (workspaceFolder) {
        const pattern = new vscode.RelativePattern(
            workspaceFolder,
            "tests/results/**/*"
        );
        const watcher = vscode.workspace.createFileSystemWatcher(pattern);
        watcher.onDidChange(refreshArtifacts, null, disposables);
        watcher.onDidCreate(refreshArtifacts, null, disposables);
        watcher.onDidDelete(refreshArtifacts, null, disposables);
        context.subscriptions.push(watcher);
    }

    vscode.workspace.onDidChangeWorkspaceFolders(
        () => {
            artifactProvider.setWorkspaceFolder(
                vscode.workspace.workspaceFolders?.[0]
            );
            void evaluateOutcomeDiagnostics(artifactProvider, diagnosticState);
        },
        undefined,
        context.subscriptions
    );

    vscode.tasks.onDidStartTaskProcess(
        e => {
            statusBar.text = `CompareVI: ${e.execution.task.name}…`;
        },
        undefined,
        context.subscriptions
    );

    vscode.tasks.onDidEndTaskProcess(
        () => {
            statusBar.text = "CompareVI: idle";
        },
        undefined,
        context.subscriptions
    );

    context.subscriptions.push(
        vscode.commands.registerCommand("comparevi.buildAndParse", buildAndParse),
        vscode.commands.registerCommand(
            "comparevi.runManualCompare",
            async () => {
                await runManualCompareCommand(repoRoot, refreshArtifacts, manualProvider);
            }
        ),
        vscode.commands.registerCommand("comparevi.manual.refresh", async () => {
            await manualProvider.refreshProfiles();
        }),
        vscode.commands.registerCommand(
            "comparevi.manual.runProfile",
            async (item?: ManualProfileTreeItem | ManualProfile) => {
                const config = getConfiguration();
                let profile: ManualProfile | undefined;
                if (item instanceof ManualProfileTreeItem) {
                    profile = item.profile;
                } else if (item && typeof item === "object" && "vis" in (item as any)) {
                    profile = item as ManualProfile;
                }
                if (!profile) {
                    profile = await pickManualProfile(config, repoRoot);
                }
                if (!profile) {
                    return;
                }
                await runProfileWithProfile(profile, config, repoRoot, refreshArtifacts, "tree", () => manualProvider.notifyStateChanged());
            }
        ),
        vscode.commands.registerCommand(
            "comparevi.manual.selectBase",
            async (item: ManualProfileTreeItem) => {
                if (!item) {
                    return;
                }
                try {
                    await selectCommitEntry(item.profile, "base", repoRoot, getConfiguration(), true);
                    manualProvider.notifyStateChanged();
                } catch (error) {
                    vscode.window.showErrorMessage((error as Error).message);
                }
            }
        ),
        vscode.commands.registerCommand(
            "comparevi.manual.selectHead",
            async (item: ManualProfileTreeItem) => {
                if (!item) {
                    return;
                }
                try {
                    await selectCommitEntry(item.profile, "head", repoRoot, getConfiguration(), true);
                    manualProvider.notifyStateChanged();
                } catch (error) {
                    vscode.window.showErrorMessage((error as Error).message);
                }
            }
        ),
        vscode.commands.registerCommand(
            "comparevi.manual.openCapture",
            async (item: ManualProfileTreeItem) => {
                if (!item) {
                    return;
                }
                const outputDir = resolveOutputDir(item.profile, repoRoot);
                const capturePath = path.join(outputDir, "lvcompare-capture.json");
                if (!fs.existsSync(capturePath)) {
                    vscode.window.showInformationMessage("Manual capture not found yet. Run a manual compare first.");
                    return;
                }
                await vscode.commands.executeCommand("vscode.open", vscode.Uri.file(capturePath));
            }
        ),
        vscode.commands.registerCommand(
            "comparevi.manual.openReport",
            async (item: ManualProfileTreeItem) => {
                if (!item) {
                    return;
                }
                const outputDir = resolveOutputDir(item.profile, repoRoot);
                const reportPath = path.join(outputDir, "compare-report.html");
                if (!fs.existsSync(reportPath)) {
                    vscode.window.showInformationMessage("Manual compare report not found yet. Run a manual compare first.");
                    return;
                }
                await vscode.commands.executeCommand("vscode.open", vscode.Uri.file(reportPath));
            }
        ),
        vscode.commands.registerCommand(
            "comparevi.startStandingPriority",
            async () => {
                const issue = await pickStandingPriorityIssue();
                if (!issue) {
                    return;
                }
                const tokenOk = await ensureAdminToken();
                if (!tokenOk) {
                    return;
                }
                await runTask(TASK_AUTO_PUSH);
            }
        ),
        vscode.commands.registerCommand(
            "comparevi.watchStandingPriority",
            async () => {
                // Robust REST watcher with QuickPick (Run Id or Branch) and status bar updates
                try {
                    const cfg = getConfiguration();
                    const resultsRoot = cfg.get<string>("watch.resultsPath", "tests/results");
                    const errorGraceMs = cfg.get<number>("watch.errorGraceMs", 120000);
                    const notFoundGraceMs = cfg.get<number>("watch.notFoundGraceMs", 90000);

                    const outPath = path.join(repoRoot, resultsRoot, "_agent", "watcher-rest.json");
                    const sessionIndex = path.join(repoRoot, resultsRoot, "session-index.json");

                    const choice = await vscode.window.showQuickPick([
                        { label: "Watch by Branch", description: "Use latest run for current branch" },
                        { label: "Watch by Run Id", description: "Provide a run id manually" }
                    ], { placeHolder: "How would you like to watch the orchestrated run?" });
                    if (!choice) { return; }

                    let args: string[] = [];
                    let selectedBranch: string | undefined;
                    let selectedRunId: string | undefined;
                    if (choice.label.startsWith("Watch by Run Id")) {
                        const runId = await vscode.window.showInputBox({ prompt: "Enter workflow run id", validateInput: v => /^(\d+)$/.test(v ?? "") ? undefined : "Enter a numeric run id" });
                        if (!runId) { return; }
                        args = ["--run-id", runId];
                        selectedRunId = runId;
                    } else {
                        // determine current branch
                        let branch = "";
                        try {
                            const r = spawnSync(process.platform === "win32" ? "git.exe" : "git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd: repoRoot, encoding: "utf8" });
                            if (r.status === 0) { branch = (r.stdout ?? "").trim(); }
                        } catch {
                            // ignore
                        }
                        if (!branch) {
                            const b = await vscode.window.showInputBox({ prompt: "Enter branch to watch", value: "develop" });
                            if (!b) { return; }
                            branch = b;
                        }
                        args = ["--branch", branch, "--workflow", ".github/workflows/ci-orchestrated.yml"];
                        selectedBranch = branch;
                    }

                    // Ensure output directory exists
                    await fs.promises.mkdir(path.dirname(outPath), { recursive: true });

                    // Prefer PowerShell wrapper to also merge session index; fallback to node directly
                    const pwsh = process.platform === "win32" ? "pwsh.exe" : "pwsh";
                    const check = spawnSync(pwsh, ["-NoLogo", "-NoProfile", "-Command", "$PSVersionTable.PSVersion"], { cwd: repoRoot });
                    const havePwsh = (check.status === 0);

                    if (havePwsh) {
                        statusBar.text = "CompareVI: watching (REST)…";
                        const psArgs: string[] = [
                            "-NoLogo", "-NoProfile", "-File",
                            path.join(repoRoot, "tools", "Watch-OrchestratedRest.ps1"),
                            ...(
                                selectedRunId
                                    ? ["-RunId", selectedRunId]
                                    : ["-Branch", (selectedBranch ?? "develop"), "-Workflow", ".github/workflows/ci-orchestrated.yml"]
                            ),
                            "-OutPath", outPath,
                            "-ErrorGraceMs", String(errorGraceMs),
                            "-NotFoundGraceMs", String(notFoundGraceMs)
                        ];
                        await new Promise<void>((resolve) => {
                            const cp = spawn(pwsh, psArgs, { cwd: repoRoot, env: process.env });
                            cp.stdout?.on("data", d => manualOutputChannel?.append(utf8Decoder.decode(d)));
                            cp.stderr?.on("data", d => manualOutputChannel?.append(utf8Decoder.decode(d)));
                            cp.on("close", async () => {
                                await refreshFromSessionIndex(resolvePreferredSessionIndexPath(repoRoot, resultsRoot), statusBar);
                                resolve();
                            });
                        });
                    } else {
                        statusBar.text = "CompareVI: watching (REST, node)…";
                        const watcherJs = path.join(repoRoot, "dist", "tools", "watchers", "orchestrated-watch.js");
                        const nodeArgs: string[] = [watcherJs, ...args, "--out", outPath, "--error-grace-ms", String(errorGraceMs), "--notfound-grace-ms", String(notFoundGraceMs)];
                        await new Promise<void>((resolve) => {
                            const cp = spawn(process.execPath, nodeArgs, { cwd: repoRoot, env: process.env });
                            cp.stdout?.on("data", d => manualOutputChannel?.append(utf8Decoder.decode(d)));
                            cp.stderr?.on("data", d => manualOutputChannel?.append(utf8Decoder.decode(d)));
                            cp.on("close", async () => {
                                await mergeWatcherIntoSessionIndex(outPath, sessionIndex);
                                await refreshFromSessionIndex(resolvePreferredSessionIndexPath(repoRoot, resultsRoot), statusBar);
                                resolve();
                            });
                        });
                    }
                } catch (err) {
                    vscode.window.showErrorMessage(`REST watcher failed: ${(err as Error).message}`);
                } finally {
                    statusBar.text = "CompareVI: idle";
                }
            }
        ),
        vscode.commands.registerCommand("comparevi.openArtifact", async (item?: ArtifactItem) => {
            await openArtifact(artifactProvider, item);
        }),
        vscode.commands.registerCommand(
            "comparevi.showArtifactSummary",
            async (item?: ArtifactItem) => {
                await showArtifactSummary(artifactProvider, item);
            }
        )
    );

    context.subscriptions.push(...disposables);

    void evaluateOutcomeDiagnostics(artifactProvider, diagnosticState);
}

export function deactivate() {}

function resolvePreferredSessionIndexPath(repoRoot: string, resultsRoot: string): string {
    const dir = path.join(repoRoot, resultsRoot);
    const v2 = path.join(dir, "session-index-v2.json");
    const v1 = path.join(dir, "session-index.json");
    if (fs.existsSync(v2)) {
        return v2;
    }
    return v1;
}

async function refreshFromSessionIndex(sessionIndexPath: string, statusBar: vscode.StatusBarItem) {
    try {
        if (!fs.existsSync(sessionIndexPath)) {
            return;
        }
        const raw = await fs.promises.readFile(sessionIndexPath, "utf8");
        const data = JSON.parse(raw);
        const rest = data?.watchers?.rest;
        if (!rest) {
            return;
        }
        const status: string = rest.status ?? "unknown";
        const conclusion: string = rest.conclusion ?? "unknown";
        const url: string | undefined = rest.htmlUrl ?? undefined;
        const label = conclusion && conclusion !== "" ? `${status}/${conclusion}` : status;
        statusBar.text = `CompareVI: ${label}`;
        statusBar.tooltip = url ? `Open run: ${url}` : "Run CompareVI tasks or watch standing priority runs.";
        if (url) {
            statusBar.command = {
                title: "Open Run",
                command: "vscode.open",
                arguments: [vscode.Uri.parse(url)]
            } as any;
        } else {
            statusBar.command = "comparevi.watchStandingPriority";
        }
    } catch {
        // ignore parse errors
    }
}

async function mergeWatcherIntoSessionIndex(watcherPath: string, sessionIndexPath: string) {
    try {
        if (!fs.existsSync(watcherPath)) { return; }
        const raw = await fs.promises.readFile(watcherPath, "utf8");
        const watch = JSON.parse(raw);
        let idx: any = {};
        if (fs.existsSync(sessionIndexPath)) {
            try { idx = JSON.parse(await fs.promises.readFile(sessionIndexPath, "utf8")); } catch { idx = {}; }
        }
        idx.watchers = idx.watchers ?? {};
        idx.watchers.rest = watch;
        await fs.promises.mkdir(path.dirname(sessionIndexPath), { recursive: true });
        await fs.promises.writeFile(sessionIndexPath, JSON.stringify(idx, null, 2), "utf8");
    } catch {
        // ignore merge errors
    }
}
