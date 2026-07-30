import { openDB } from 'idb';
import { create } from 'zustand';
import { defaultProject } from '../model/factories';
import type { Folder, MapObject, Project } from '../model/types';

const database = openDB('obstacle-plotter', 1, {
  upgrade(db) { db.createObjectStore('projects'); },
});
const save = async (project: Project) => { await (await database).put('projects', project, project.id); };

type Store = {
  project: Project;
  history: Project[];
  future: Project[];
  loaded: boolean;
  replace: (project: Project, history?: boolean) => void;
  updateObject: (id: string, mutate: (object: MapObject) => MapObject) => void;
  updateFolder: (id: string, mutate: (folder: Folder) => Folder, history?: boolean) => void;
  select: (id: string | null) => void;
  undo: () => void;
  redo: () => void;
  loadLast: () => Promise<void>;
};

function touch(project: Project): Project { return { ...project, updatedAt: new Date().toISOString() }; }
export const useProjectStore = create<Store>((set, get) => ({
  project: defaultProject(), history: [], future: [], loaded: false,
  replace(project, history = true) {
    const current = get().project;
    const next = touch(project);
    set({ project: next, history: history ? [...get().history.slice(-199), current] : get().history, future: history ? [] : get().future });
    void save(next);
  },
  updateObject(id, mutate) {
    const project = get().project;
    get().replace({ ...project, objects: project.objects.map((object) => object.id === id ? { ...mutate(object), updatedAt: new Date().toISOString() } : object) });
  },
  updateFolder(id, mutate, history = true) {
    const project = get().project;
    get().replace({ ...project, folders: project.folders.map((folder) => folder.id === id ? mutate(folder) : folder) }, history);
  },
  select(id) { get().replace({ ...get().project, selectedObjectId: id }, false); },
  undo() {
    const history = get().history;
    if (history.length === 0) return;
    const previous = history.at(-1)!;
    set({ project: previous, history: history.slice(0, -1), future: [get().project, ...get().future] });
    void save(previous);
  },
  redo() {
    const [next, ...future] = get().future;
    if (!next) return;
    set({ project: next, future, history: [...get().history.slice(-199), get().project] });
    void save(next);
  },
  async loadLast() {
    const db = await database;
    const keys = await db.getAllKeys('projects');
    if (keys.length > 0) {
      const project = await db.get('projects', keys.at(-1)!);
      if (project) set({ project: project as Project });
    }
    set({ loaded: true });
  },
}));
