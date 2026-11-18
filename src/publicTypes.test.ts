import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * `index.ts` re-exports the public types by name, in a list kept by hand.
 *
 * A list like that drifts silently: a type added to `types.ts` and left out of
 * it is still exported *from its own module*, so nothing in this repository
 * fails — `tsc` is satisfied, the build emits a `.d.ts` containing it, and the
 * omission only shows up in a consumer, where the import resolves to `any`
 * rather than erroring. That is what happened to `EngineErrorOperation`: added
 * as public vocabulary in 1.3.0 for hosts to group failures by, shipped
 * unreachable, and found only when the app tried to import it.
 *
 * So the list is checked against its source rather than trusted.
 */
const read = (file: string) => readFileSync(join(__dirname, file), 'utf8');

function exportedFromTypes(): string[] {
  return [...read('types.ts').matchAll(/^export (?:type|interface) ([A-Za-z0-9_]+)/gm)]
    .flatMap(match => (match[1] ? [match[1]] : []))
    .sort();
}

function reExportedByIndex(): string[] {
  const block = /export type \{([^}]*)\} from '\.\/types';/.exec(read('index.ts'));
  if (!block) throw new Error("index.ts has no `export type { ... } from './types'` block");
  return (block[1] ?? '')
    .split(',')
    .map(name => name.trim())
    .filter(Boolean)
    .sort();
}

describe('the public type surface', () => {
  it('re-exports every type that types.ts exports', () => {
    const missing = exportedFromTypes().filter(name => !reExportedByIndex().includes(name));
    expect(missing).toEqual([]);
  });

  it('re-exports nothing types.ts does not have', () => {
    const exported = exportedFromTypes();
    const stale = reExportedByIndex().filter(name => !exported.includes(name));
    expect(stale).toEqual([]);
  });
});
