import { requireNativeModule } from 'expo-modules-core';
import { Platform } from 'react-native';

import type { AudioEngine } from './AudioEngine';
import { flattenBrowseTree } from './browseTree';
import type { BrowseNode, EngineEvent, PlaybackState, Progress, MediaId } from './types';

/**
 * The native module, plus the one thing that cannot be a straight pass-through.
 *
 * Expo's event emitter is **name-based** — `addListener('onProgress', fn)`,
 * one subscription per event — while `AudioEngine.addListener` takes a single
 * listener and a discriminated union. That union is the better API for a
 * consumer: one subscription, one exhaustive switch, no chance of forgetting
 * that `onError` exists. But it is not what the runtime does, and declaring it
 * over `requireNativeModule` was simply a lie about the shape — it typechecked
 * and then threw "Value is a function, expected a String" the first time
 * anything subscribed.
 *
 * `setBrowseTree` is the other one, for a duller reason: the tree cannot cross
 * as a tree, so it is flattened here rather than making every host do it.
 *
 * So the union is assembled here, over the six named events the module
 * declares. If a name is added natively it must be added to `EVENTS` too;
 * that duplication is the price of the nicer surface, and it is small and
 * visible rather than spread across call sites.
 */

type NativeModule = Omit<AudioEngine, 'addListener' | 'setBrowseTree'> & {
  addListener(name: string, listener: (payload: any) => void): { remove(): void };
  setBrowseTree(title: string, nodes: ReturnType<typeof flattenBrowseTree>): Promise<void>;
};

const native = requireNativeModule<NativeModule>('YuzicEngine');

const EVENTS = [
  'onStateChange',
  'onTrackChange',
  'onProgress',
  'onQueueChange',
  'onError',
  'onRemoteCommand',
] as const;

function toEvent(name: (typeof EVENTS)[number], payload: any): EngineEvent | null {
  switch (name) {
    case 'onStateChange':
      return { type: 'stateChange', state: payload.state as PlaybackState };
    case 'onTrackChange':
      return {
        type: 'trackChange',
        index: payload.index as number,
        id: (payload.id ?? null) as MediaId | null,
        previousListenedSec: payload.previousListenedSec as number | undefined,
      };
    case 'onProgress':
      return {
        type: 'progress',
        progress: {
          positionSec: payload.positionSec,
          durationSec: payload.durationSec,
          bufferedSec: payload.bufferedSec ?? 0,
        } as Progress,
      };
    case 'onQueueChange':
      return { type: 'queueChange' };
    case 'onError':
      return { type: 'error', code: payload.code, message: payload.message, id: payload.id };
    case 'onRemoteCommand':
      return { type: 'remoteCommand', command: payload.command, payload: payload.payload };
    default:
      return null;
  }
}

/**
 * Every method `AudioEngine` promises, listed because TypeScript's interface
 * is gone by the time this runs and the check below needs it at runtime.
 *
 * Keep in step with `AudioEngine`. A name missing here is not dangerous — that
 * method simply falls back to the old behaviour — but a name here the
 * interface has dropped will claim a platform gap that does not exist.
 */
const ENGINE_METHODS: readonly string[] = [
  'setup', 'teardown',
  'setQueue', 'append', 'insertAt', 'removeAt', 'move', 'clearQueue',
  'getQueue', 'getActiveIndex',
  'play', 'pause', 'stop', 'seekTo', 'skipToNext', 'skipToPrevious',
  'skipToIndex',
  'setVolume', 'setSpeed', 'setRepeatMode', 'getState', 'getProgress',
  'setCrossfade', 'setEqualizer', 'setReplayGain', 'setSampleRateMode',
  'configureCache', 'clearCache', 'cacheStats', 'evict',
  'setClientCertificate', 'clientCertificateRequest',
  'setBrowseTree', 'clearBrowseTree', 'setCommands',
  'sleepAfter', 'cancelSleep',
  'addListener',
];

const base: AudioEngine = Object.assign(Object.create(native), {
  setBrowseTree(root: BrowseNode): Promise<void> {
    return native.setBrowseTree(root.title, flattenBrowseTree(root));
  },

  addListener(listener: (event: EngineEvent) => void): () => void {
    const subscriptions = EVENTS.map(name =>
      native.addListener(name, (payload: any) => {
        const event = toEvent(name, payload ?? {});
        if (event) listener(event);
      })
    );
    return () => subscriptions.forEach(subscription => subscription.remove());
  },
}) as AudioEngine;

/**
 * Say which platform is missing a method, rather than letting it read as a
 * broken one.
 *
 * The facade is `Object.create(native)`, so a method a platform has not
 * implemented is simply an absent property, and calling it throws
 * `X is not a function` — indistinguishable from a typo, a bad import, or a
 * native module that failed to link. Android is currently missing eleven of
 * the methods listed above, so this is the common case rather than an edge.
 *
 * The rejection is deliberately *asynchronous*, matching every other method
 * here: a caller that already handles a failed promise handles this too, and
 * one that awaits gets the message rather than a synchronous throw part-way
 * through a queue edit.
 *
 * This does not make an unimplemented method work. It makes "not built yet"
 * distinguishable from "built wrong" at the boundary. `setCrossfade` on
 * Android is the argument for caring: it exists, accepts, and silently does
 * nothing, and no amount of reading the call site reveals that — the only way
 * anyone found out was watching logcat for a decoder that never appeared.
 */
export const YuzicEngine: AudioEngine = new Proxy(base, {
  get(target, property, receiver) {
    const existing = Reflect.get(target, property, receiver);
    if (existing !== undefined) return existing;
    if (typeof property !== 'string' || !ENGINE_METHODS.includes(property)) {
      return existing;
    }
    return () =>
      Promise.reject(
        new Error(
          `yuzic-engine: ${property}() is not implemented on ${Platform.OS}. ` +
            `It exists in the AudioEngine interface, but this platform's native ` +
            `module does not export it.`
        )
      );
  },
}) as AudioEngine;
