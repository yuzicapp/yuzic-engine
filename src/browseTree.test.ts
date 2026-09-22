import { flattenBrowseTree } from './browseTree';
import type { BrowseNode } from './types';

/**
 * The flatten side of the bridge crossing.
 *
 * Its counterpart — rebuilding — is tested in Swift, and the two agree on the
 * same rules: parents before children, first duplicate wins, order preserved.
 * Worth pinning on both sides, because a disagreement here shows up as a car
 * displaying one album and playing another.
 */
describe('flattenBrowseTree', () => {
  const leaf = (id: string): BrowseNode => ({
    id,
    title: id,
    playable: { id, uri: `https://example.test/${id}`, title: id },
  });

  const library = (): BrowseNode => ({
    id: 'root',
    title: 'Library',
    children: [
      { id: 'albums', title: 'Albums', children: [{ id: 'album:1', title: 'First', children: [leaf('t:1'), leaf('t:2')] }] },
      { id: 'playlists', title: 'Playlists' },
    ],
  });

  it('emits parents before their children', () => {
    // The native side rebuilds in one pass and drops nodes whose parent it has
    // not seen, so this ordering is a contract rather than a nicety.
    const ids = flattenBrowseTree(library()).map(n => n.id);
    expect(ids.indexOf('albums')).toBeLessThan(ids.indexOf('album:1'));
    expect(ids.indexOf('album:1')).toBeLessThan(ids.indexOf('t:1'));
  });

  it('records each node parent', () => {
    const byId = Object.fromEntries(flattenBrowseTree(library()).map(n => [n.id, n]));
    expect(byId['albums']?.parentId).toBeUndefined();
    expect(byId['album:1']?.parentId).toBe('albums');
    expect(byId['t:2']?.parentId).toBe('album:1');
  });

  it('does not send the root itself', () => {
    // The native side supplies its own container, so an empty tree still has a
    // title to show rather than a blank screen.
    expect(flattenBrowseTree(library()).map(n => n.id)).not.toContain('root');
  });

  it('preserves sibling order', () => {
    const ids = flattenBrowseTree(library()).map(n => n.id);
    expect(ids.indexOf('albums')).toBeLessThan(ids.indexOf('playlists'));
  });

  it('carries what plays', () => {
    const node = flattenBrowseTree(library()).find(n => n.id === 't:1');
    expect(node?.playable?.uri).toBe('https://example.test/t:1');
  });

  it('keeps the first of a repeated id', () => {
    // An id in two places makes a tap ambiguous: selection resolves by id, so
    // the car could play something other than what it displayed.
    const tree: BrowseNode = {
      id: 'root',
      title: 'Library',
      children: [
        { id: 'a', title: 'Original', children: [leaf('shared')] },
        { id: 'b', title: 'Other', children: [leaf('shared')] },
      ],
    };
    const shared = flattenBrowseTree(tree).filter(n => n.id === 'shared');
    expect(shared).toHaveLength(1);
    expect(shared[0]?.parentId).toBe('a');
  });

  it('carries artwork headers, layout, icon and action', () => {
    // Anything left out here never reaches either platform. The headers were,
    // for as long as they existed, so a protected server's covers were blank.
    const tree: BrowseNode = {
      id: 'root',
      title: 'Library',
      children: [{
        id: 'albums',
        title: 'Albums',
        icon: 'albums',
        layout: 'grid',
        children: [{
          id: 'album:1',
          title: 'First',
          artworkUri: 'https://example.test/cover',
          artworkHeaders: { Authorization: 'Basic abc' },
          children: [{ id: 'album:1/shuffle', title: 'Shuffle', action: 'shuffle' }, leaf('t:1')],
        }],
      }],
    };
    const byId = Object.fromEntries(flattenBrowseTree(tree).map(n => [n.id, n]));
    expect(byId['albums']).toMatchObject({ icon: 'albums', layout: 'grid' });
    expect(byId['album:1']?.artworkHeaders).toEqual({ Authorization: 'Basic abc' });
    expect(byId['album:1/shuffle']?.action).toBe('shuffle');
  });

  it('leaves optional fields off rather than sending them empty', () => {
    const node = flattenBrowseTree(library()).find(n => n.id === 'albums');
    expect(node).not.toHaveProperty('artworkHeaders');
    expect(node).not.toHaveProperty('layout');
    expect(node).not.toHaveProperty('action');
  });

  it('flattens an empty tree to nothing', () => {
    expect(flattenBrowseTree({ id: 'root', title: 'Library' })).toEqual([]);
  });
});
