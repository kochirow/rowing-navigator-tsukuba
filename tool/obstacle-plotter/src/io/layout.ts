import type { Project } from '../model/types';

export function exportLayout(project: Project): string {
  const layout = {
    layoutVersion: 1,
    profileVersion: project.profileVersion,
    folders: project.folders.map((folder) => ({ id: folder.id, name: folder.name, parentId: folder.parentFolderId, order: folder.order })),
    objects: Object.fromEntries(project.objects.map((object) => [object.exportId, {
      folderId: object.parentFolderId,
      order: object.order,
      description: object.description,
      verificationStatus: object.verificationStatus,
      style: object.style,
    }])),
  };
  return `${JSON.stringify(layout, null, 2)}\n`;
}
