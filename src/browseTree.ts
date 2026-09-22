import type { BrowseAction, BrowseIcon, BrowseLayout, BrowseNode, Track } from './types';

/**
 * One node on the way across the bridge.
 *
 * Flat because a native `Record` cannot contain itself — Expo's `@Field` has
 * no way to describe recursion — so the tree travels as a list with parent
 * references and is rebuilt on the far side.
 *
 * This is a bridge artifact and nothing more. It is exported so it can be
 * tested, not so hosts have to think about it: `setBrowseTree` takes the
 * ordinary nested tree and flattens it here.
 */
export interface FlatBrowseNode {
  id: string;
  parentId?: string;
  title: string;
  subtitle?: string;
  artworkUri?: string;
  artworkHeaders?: Record<string, string>;
  playable?: Track;
  layout?: BrowseLayout;
  icon?: BrowseIcon;
  action?: BrowseAction;
}

/**
 * Depth-first, parents before children, so the native side can rebuild in one
 * pass without buffering orphans.
 *
 * A node repeated under two parents keeps its first appearance. Ids are how a
 * selection is resolved, so the same id in two places would make a tap
 * ambiguous — better to drop the duplicate here, where it is a shallow bug,
 * than to have the car play something other than what it displayed.
 */
export function flattenBrowseTree(root: BrowseNode): FlatBrowseNode[] {
  const out: FlatBrowseNode[] = [];
  const seen = new Set<string>();

  const visit = (node: BrowseNode, parentId?: string) => {
    if (seen.has(node.id)) return;
    seen.add(node.id);
    // Every field the host set, or the far side never sees it. This list was
    // written before `artworkHeaders` existed and was never extended, so the
    // headers were declared on `BrowseNode`, accepted by the native record,
    // and dropped here, and a protected server's thumbnails were blank in the
    // car on both platforms.
    out.push({
      id: node.id,
      parentId,
      title: node.title,
      subtitle: node.subtitle,
      artworkUri: node.artworkUri,
      ...(node.artworkHeaders ? { artworkHeaders: node.artworkHeaders } : {}),
      playable: node.playable,
      ...(node.layout ? { layout: node.layout } : {}),
      ...(node.icon ? { icon: node.icon } : {}),
      ...(node.action ? { action: node.action } : {}),
    });
    for (const child of node.children ?? []) visit(child, node.id);
  };

  // The root itself is not sent: the native side supplies its own container so
  // that an empty tree still has a title to show. Its children become the
  // top-level entries.
  for (const child of root.children ?? []) visit(child);
  return out;
}
