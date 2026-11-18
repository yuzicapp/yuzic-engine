/**
 * The facade's platform-gap behaviour.
 *
 * Everything else here is exercised on a device; this is the one part whose
 * whole purpose is what happens when the native module is *missing* something,
 * which is easier to construct in a test than to reproduce on a phone.
 */

/** A native module with a deliberate hole in it, standing in for Android. */
const nativeStub: Record<string, unknown> = {
  play: jest.fn(async () => undefined),
  setBrowseTree: jest.fn(async () => undefined),
  addListener: jest.fn(() => ({ remove: jest.fn() })),
  // `setSpeed`, `getQueue`, `insertAt` and the rest are absent, exactly as
  // they are on Android today.
};

jest.mock('expo-modules-core', () => ({
  requireNativeModule: () => nativeStub,
}));

jest.mock('react-native', () => ({ Platform: { OS: 'android' } }));

import { YuzicEngine } from './YuzicEngine';

/**
 * The error event's shape.
 *
 * `onError` used to carry a code and a sentence, and the sentence was built by
 * interpolating the track's title and the underlying error. A host could not
 * group failures without matching prose — and on iOS the interpolated error
 * carries the URL that failed, credentials included, so the one field it had
 * was the one it could not safely log. The parts travel beside the sentence
 * now; this pins that they survive the bridge.
 */
describe('the error event', () => {
  function emitted(payload: Record<string, unknown>) {
    const listeners: Record<string, (p: unknown) => void> = {};
    (nativeStub.addListener as jest.Mock).mockImplementation(
      (name: string, fn: (p: unknown) => void) => {
        listeners[name] = fn;
        return { remove: jest.fn() };
      }
    );

    const seen: unknown[] = [];
    const unsubscribe = YuzicEngine.addListener(event => seen.push(event));
    listeners.onError?.(payload);
    unsubscribe();
    return seen[0];
  }

  it('carries the operation, the track and the underlying error', () => {
    expect(
      emitted({
        code: 'PLAYBACK_FAILED',
        message: 'Could not open Arrival: ...',
        id: 'track-42',
        operation: 'open',
        domain: 'NSURLErrorDomain',
        underlyingCode: -1008,
      })
    ).toEqual({
      type: 'error',
      code: 'PLAYBACK_FAILED',
      message: 'Could not open Arrival: ...',
      id: 'track-42',
      operation: 'open',
      domain: 'NSURLErrorDomain',
      underlyingCode: -1008,
    });
  });

  /**
   * `CROSSFADE_DISABLED` is not a playback failure and neither platform sends
   * an operation with it, so the fields are absent rather than empty.
   */
  it('leaves the new fields undefined when the native side sends none', () => {
    expect(
      emitted({ code: 'CROSSFADE_DISABLED', message: 'Crossfade turned off.' })
    ).toMatchObject({
      type: 'error',
      code: 'CROSSFADE_DISABLED',
      operation: undefined,
      domain: undefined,
      underlyingCode: undefined,
    });
  });
});

describe('the facade over a partial native module', () => {
  it('passes through methods the platform does implement', async () => {
    await YuzicEngine.play();
    expect(nativeStub.play).toHaveBeenCalled();
  });

  /**
   * The point of the whole exercise. Before this, an unimplemented method was
   * an absent property and calling it threw `X is not a function` — the same
   * message a typo or an unlinked module produces, which is why a real
   * platform gap read as a broken install.
   */
  it('rejects a method the platform lacks, naming the method and platform', async () => {
    await expect(YuzicEngine.setSpeed(2)).rejects.toThrow(
      /setSpeed\(\) is not implemented on android/
    );
  });

  it('says the interface has it, so the reader knows it is a gap not a typo', async () => {
    await expect(YuzicEngine.getQueue()).rejects.toThrow(/AudioEngine interface/);
  });

  /**
   * Asynchronous on purpose. Callers already handle a rejected promise from
   * every other method, and `createEngineBackend`'s queue edits run several
   * calls in sequence — a synchronous throw part-way through would abandon the
   * ones after it.
   */
  it('rejects rather than throwing synchronously', async () => {
    // The promise is captured rather than discarded: an unhandled rejection
    // takes the whole test run down, which is itself a small demonstration
    // that this rejects rather than throws.
    let pending: Promise<unknown> | undefined;
    expect(() => {
      pending = YuzicEngine.insertAt(0, []);
    }).not.toThrow();
    await expect(pending).rejects.toThrow(/insertAt/);
  });

  /** Not every absent property is a missing engine method. */
  it('leaves unknown properties alone', () => {
    expect((YuzicEngine as unknown as Record<string, unknown>).notAMethod).toBeUndefined();
  });
});
