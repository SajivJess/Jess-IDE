import type { Project, Task, TaskEvent } from '../src/domain.js';

export interface Capabilities {
  taskSubmission: boolean;
  agentMode: 'simulated' | 'local-only';
  files: boolean;
  fileStorage: 'review-snapshot';
  gitApprovals: false;
  eventTransport: 'replay';
  chatHistory: true;
  chatSubmission: false;
}
export interface PortalApi {
  home(sort?: 'recent' | 'name', offset?: number): Promise<{ projects: HomeProject[]; nextOffset: number | null; total: number; recent: HomeProject | null }>;
  searchWorkspace(query: string): Promise<{ results: { kind: string; projectId: string; conversationId: string | null; title: string; detail: string }[] }>;
  openProject(id: string, conversationId?: string): Promise<{ projectId: string; conversationId: string | null }>;
  saveProfile(displayName: string): Promise<{ user: { displayName: string | null } }>;
  conversations(projectId: string, search?: string, archived?: boolean): Promise<{ conversations: Conversation[] }>;
  createConversation(projectId: string, repositoryId: string, title: string): Promise<Conversation>;
  updateConversation(id: string, revision: number, change: { title?: string; archived?: boolean }): Promise<Conversation>;
  conversation(id: string): Promise<Conversation>;
  messages(id: string, before?: number): Promise<{ messages: ChatMessage[]; nextBefore: number | null }>;
  chatEvents(id: string, after?: number): Promise<{ events: { sequence: number; kind: string; payload: Record<string, unknown>; createdAt: string }[]; nextCursor: number; hasMore: boolean }>;
  transcript(id: string): Promise<{ filename: string; markdown: string }>;
  projectContext(id: string): Promise<ProjectContext>;
  saveContext(id: string, revision: number, summary: string, handoff: string): Promise<ProjectContext>;
  exportContext(id: string): Promise<{ revision: number; project: string; handoff: string }>;
  repositories(): Promise<{ repositories: Repository[] }>;
  workspaces(): Promise<{ workspaces: Workspace[] }>;
  createWorkspace(taskId: string, repositoryId: string): Promise<Workspace>;
  files(id: string, path?: string, offset?: number): Promise<{ entries: { name: string; path: string; kind: 'directory' | 'text' | 'unavailable'; size: number; reason: string | null }[]; nextOffset: number | null }>;
  readFile(id: string, path: string): Promise<WorkspaceFile>;
  writeFile(id: string, path: string, content: string, etag: string): Promise<WorkspaceFile>;
  fileDiff(id: string, path: string): Promise<{ path: string; branch: string; baseCommit: string; etag: string; diff: string; truncated: boolean; changed: boolean; approvalAvailable: false }>;
  session(): Promise<{ ok: true; capabilities: Capabilities; user?: { displayName: string | null } }>;
  ready(): Promise<{ status: 'ready' }>;
  login(password: string): Promise<{ ok: true }>;
  logout(): Promise<{ ok: true }>;
  projects(before?: string): Promise<{ projects: Project[]; nextCursor: string | null }>;
  tasks(before?: string): Promise<{ tasks: Task[]; nextCursor: string | null }>;
  createProject(name: string): Promise<Project>;
  submit(projectId: string, prompt: string, key: string): Promise<{ task: Task; replayed: boolean }>;
  task(id: string): Promise<Task>;
  events(id: string, after?: number): Promise<{ events: TaskEvent[]; nextCursor: number; hasMore: boolean; taskStatus: Task['status'] }>;
  cancel(id: string): Promise<Task>;
}
export interface Repository { id: string; name: string; githubUrl: string; branch: string; baseCommit: string }
export interface Workspace extends Omit<Repository, 'id'> { id: string; repositoryId: string; taskId: string; revision: number; mode: 'review-only'; createdAt: string }
export interface WorkspaceFile { path: string; content: string; etag: string; version: number; size: number }
export interface Conversation { id: string; projectId: string; repositoryId: string; title: string; provider: string; profileBinding: string | null; nativeSessionId: string | null; eventSequence: number; createdAt: string; updatedAt: string; archived: boolean; revision: number; lastStatus: string | null }
export interface ChatMessage { id: string; sequence: number; prompt: string; response: string | null; status: string; error: string | null; createdAt: string; finishedAt: string | null }
export interface ProjectContext { revision: number; summary: string; handoff: string }
export interface HomeProject { id: string; name: string; createdAt: string; lastOpenedAt: string | null; lastActivityAt: string; repository: Repository | null; conversation: { id: string; title: string; updatedAt: string; hasNativeSession: boolean; lastStatus: string | null } | null }
export class ApiError extends Error { status: number; constructor(status: number, message: string); }
export function createApi(fetcher?: typeof fetch): PortalApi;
