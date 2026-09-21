import * as path from 'path';
import { AndroidConfig, XML } from '@expo/config-plugins';

/**
 * The car declarations in the library manifest, which merges into every host
 * app without a prebuild.
 *
 * Each car reads its own keys and says nothing when one is missing: Android
 * Automotive skipped this service with one debug line in its log, "No opt-in
 * info found", while the Auto key was in place the whole time.
 */
const main = path.join(__dirname, '..', 'android', 'src', 'main');

async function readManifest() {
  return AndroidConfig.Manifest.readAndroidManifestAsync(path.join(main, 'AndroidManifest.xml'));
}

async function metaData() {
  // A library's <application> is unnamed, so the host-app lookup would throw.
  const application = (await readManifest()).manifest.application?.[0];
  if (!application) throw new Error('library manifest has no <application>');
  return Object.fromEntries(
    (application['meta-data'] ?? []).map(entry => [
      entry.$['android:name'],
      entry.$['android:resource'],
    ])
  );
}

describe('car declarations', () => {
  it('declares the app to Android Auto', async () => {
    expect((await metaData())['com.google.android.gms.car.application']).toBe(
      '@xml/automotive_app_desc'
    );
  });

  it('declares the app to Android Automotive', async () => {
    // Automotive reads this key, not the Auto one above, and Google's
    // Automotive checklist asks for it. The launcher opt-in below is what gets
    // the app into the media app; this is what says it is a media app.
    expect((await metaData())['com.android.automotive']).toBe('@xml/automotive_app_desc');
  });

  it('opts the media service into the Automotive launcher', async () => {
    // Every host has a launcher activity of its own, and the launcher treats
    // such an app as an ordinary one unless its media service says otherwise.
    // Without this it is missing from the media app's sources.
    const application = (await readManifest()).manifest.application?.[0] as any;
    const service = application.service.find(
      (entry: any) => entry.$['android:name'] === 'dev.yuzic.engine.PlaybackService'
    );
    const launchable = (service['meta-data'] ?? []).find(
      (entry: any) => entry.$['android:name'] === 'androidx.car.app.launchable'
    );
    expect(launchable?.$['android:value']).toBe('true');
  });

  it('claims media in the descriptor both keys point at', async () => {
    const descriptor: any = await XML.readXMLAsync({
      path: path.join(main, 'res', 'xml', 'automotive_app_desc.xml'),
    });
    const uses = descriptor.automotiveApp.uses.map((entry: any) => entry.$.name);
    expect(uses).toEqual(['media']);
  });

  it('does not require car hardware', async () => {
    // Required, it would make every phone build of every host uninstallable
    // on phones. Only a build meant for cars should say that, and the host
    // decides which build that is.
    const features = ((await readManifest()).manifest['uses-feature'] ?? []) as any[];
    const automotive = features.find(
      entry => entry.$['android:name'] === 'android.hardware.type.automotive'
    );
    expect(automotive?.$['android:required']).not.toBe('true');
  });
});
