// eslint-disable-next-line @typescript-eslint/no-require-imports
const plugin = require('../app.plugin.js');

/**
 * The config plugin's two transformations.
 *
 * Worth testing precisely because a wrong config plugin fails *silently*: the
 * app builds, runs, plays — and then stops the moment the screen locks. There
 * is no error anywhere, and every test that keeps the app in the foreground
 * passes.
 */
describe('config plugin', () => {
  describe('background audio', () => {
    it('adds the audio background mode', () => {
      const plist = plugin.addBackgroundAudio({});
      expect(plist.UIBackgroundModes).toEqual(['audio']);
    });

    it('keeps modes the app already declared', () => {
      // Clobbering an app's own list is how you break its push handling while
      // fixing its audio.
      const plist = plugin.addBackgroundAudio({ UIBackgroundModes: ['fetch', 'remote-notification'] });
      expect(plist.UIBackgroundModes).toEqual(['fetch', 'remote-notification', 'audio']);
    });

    it('is idempotent', () => {
      // Prebuild can run repeatedly over an existing plist.
      let plist = plugin.addBackgroundAudio({});
      plist = plugin.addBackgroundAudio(plist);
      expect(plist.UIBackgroundModes).toEqual(['audio']);
    });
  });

  describe('CarPlay scene', () => {
    it('names the delegate class the system looks up', () => {
      // Without this entry CarPlay never constructs the delegate and the app
      // just does not appear on the car's home screen — no error anywhere.
      const plist = plugin.addCarPlayScene({});
      const scenes =
        plist.UIApplicationSceneManifest.UISceneConfigurations
          .CPTemplateApplicationSceneSessionRoleApplication;
      expect(scenes[0].UISceneDelegateClassName).toBe('YuzicCarPlaySceneDelegate');
    });

    it('keeps scene roles the app already declared', () => {
      const plist = plugin.addCarPlayScene({
        UIApplicationSceneManifest: {
          UISceneConfigurations: {
            UIWindowSceneSessionRoleApplication: [{ UISceneConfigurationName: 'Default' }],
          },
        },
      });
      const roles = plist.UIApplicationSceneManifest.UISceneConfigurations;
      // Clobbering this is how you fix CarPlay and break the phone app.
      expect(roles.UIWindowSceneSessionRoleApplication).toHaveLength(1);
      expect(roles.CPTemplateApplicationSceneSessionRoleApplication).toHaveLength(1);
    });

    it('is idempotent', () => {
      let plist = plugin.addCarPlayScene({});
      plist = plugin.addCarPlayScene(plist);
      expect(
        plist.UIApplicationSceneManifest.UISceneConfigurations
          .CPTemplateApplicationSceneSessionRoleApplication
      ).toHaveLength(1);
    });

    it('does not fabricate the CarPlay entitlement', () => {
      // It has to be granted by Apple per app. Writing it here would produce a
      // build that fails to sign with a far more cryptic message.
      const plist = plugin.addCarPlayScene({});
      expect(JSON.stringify(plist)).not.toContain('carplay-audio');
    });
  });

  describe('playback service', () => {
    const emptyManifest = () => ({ manifest: {} }) as any;
    const application = () => ({}) as any;

    it('declares the media-playback foreground service permission', () => {
      const manifest = plugin.addPlaybackService(emptyManifest(), application());
      const names = manifest.manifest['uses-permission'].map((p: any) => p.$['android:name']);
      // Separate from FOREGROUND_SERVICE and required from API 34. Without it
      // the service throws on start, on the newest devices only.
      expect(names).toContain('android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK');
      expect(names).toContain('android.permission.FOREGROUND_SERVICE');
    });

    it('registers the service as mediaPlayback', () => {
      const app = application();
      plugin.addPlaybackService(emptyManifest(), app);
      const service = app.service[0];
      expect(service.$['android:name']).toBe('dev.yuzic.engine.PlaybackService');
      expect(service.$['android:foregroundServiceType']).toBe('mediaPlayback');
    });

    it('advertises both the media3 and the legacy browser action', () => {
      const app = application();
      plugin.addPlaybackService(emptyManifest(), app);
      const actions = app.service[0]['intent-filter'][0].action.map((a: any) => a.$['android:name']);
      // Head units still resolve media browsers by the legacy action; dropping
      // it makes the app invisible in some cars while looking fine everywhere.
      expect(actions).toContain('androidx.media3.session.MediaLibraryService');
      expect(actions).toContain('android.media.browse.MediaBrowserService');
    });

    it('does not duplicate on a second run', () => {
      const manifest = emptyManifest();
      const app = application();
      plugin.addPlaybackService(manifest, app);
      plugin.addPlaybackService(manifest, app);
      expect(app.service).toHaveLength(1);
      const names = manifest.manifest['uses-permission'].map((p: any) => p.$['android:name']);
      expect(new Set(names).size).toBe(names.length);
    });

    it('leaves permissions the app already declared alone', () => {
      const manifest = {
        manifest: { 'uses-permission': [{ $: { 'android:name': 'android.permission.CAMERA' } }] },
      } as any;
      plugin.addPlaybackService(manifest, application());
      const names = manifest.manifest['uses-permission'].map((p: any) => p.$['android:name']);
      expect(names).toContain('android.permission.CAMERA');
    });
  });
  describe('options', () => {
    it('turns every car surface on when the host passes none', () => {
      // yuzic lists the plugin with no options, and must keep what it had.
      expect(plugin.resolveOptions(undefined)).toEqual({
        carplay: true,
        androidAuto: true,
        automotive: true,
      });
    });

    it('turns off only what the host names', () => {
      expect(plugin.resolveOptions({ automotive: false })).toEqual({
        carplay: true,
        androidAuto: true,
        automotive: false,
      });
    });
  });

  describe('CarPlay opt-out', () => {
    it('takes its own scene back out and keeps the host scenes', () => {
      const plist = plugin.addCarPlayScene({
        UIApplicationSceneManifest: {
          UISceneConfigurations: {
            CPTemplateApplicationSceneSessionRoleApplication: [
              { UISceneConfigurationName: 'HostCarPlay' },
            ],
          },
        },
      });
      plugin.removeCarPlayScene(plist);
      const scenes =
        plist.UIApplicationSceneManifest.UISceneConfigurations
          .CPTemplateApplicationSceneSessionRoleApplication;
      expect(scenes.map((s: any) => s.UISceneConfigurationName)).toEqual(['HostCarPlay']);
    });

    it('drops the role when its scene was the only one', () => {
      const plist = plugin.removeCarPlayScene(plugin.addCarPlayScene({}));
      expect(
        plist.UIApplicationSceneManifest.UISceneConfigurations
          .CPTemplateApplicationSceneSessionRoleApplication
      ).toBeUndefined();
    });

    it('leaves a plist with no scenes alone', () => {
      expect(plugin.removeCarPlayScene({})).toEqual({});
    });
  });

  describe('Android car opt-out', () => {
    const on = { carplay: true, androidAuto: true, automotive: true };
    const setUp = () => {
      const manifest = { manifest: { $: {} } } as any;
      const app = {} as any;
      plugin.addPlaybackService(manifest, app);
      return { manifest, app };
    };
    const marker = (entries: any[] | undefined, name: string) =>
      (entries ?? []).find((e: any) => e.$['android:name'] === name)?.$['tools:node'];

    it('adds nothing when every car is on', () => {
      // The declarations live in the library manifest; with the defaults the
      // host's manifest must come out exactly as it did before options existed.
      const { manifest, app } = setUp();
      const before = JSON.stringify({ manifest, app });
      plugin.configureCarDeclarations(manifest, app, on);
      expect(JSON.stringify({ manifest, app })).toBe(before);
    });

    it('removes the Android Auto key alone', () => {
      const { manifest, app } = setUp();
      plugin.configureCarDeclarations(manifest, app, { ...on, androidAuto: false });
      expect(marker(app['meta-data'], 'com.google.android.gms.car.application')).toBe('remove');
      expect(marker(app['meta-data'], 'com.android.automotive')).toBeUndefined();
      expect(manifest.manifest.$['xmlns:tools']).toBe('http://schemas.android.com/tools');
    });

    it('removes both Automotive declarations together', () => {
      // The key says it is a media app and the service opt-in puts it in the
      // media app; one without the other is half a car.
      const { manifest, app } = setUp();
      plugin.configureCarDeclarations(manifest, app, { ...on, automotive: false });
      expect(marker(app['meta-data'], 'com.android.automotive')).toBe('remove');
      expect(marker(app.service[0]['meta-data'], 'androidx.car.app.launchable')).toBe('remove');
      expect(marker(app['meta-data'], 'com.google.android.gms.car.application')).toBeUndefined();
    });

    it('turns a declaration the host wrote itself into a removal', () => {
      const { manifest, app } = setUp();
      app['meta-data'] = [
        {
          $: {
            'android:name': 'com.google.android.gms.car.application',
            'android:resource': '@xml/automotive_app_desc',
          },
        },
      ];
      plugin.configureCarDeclarations(manifest, app, { ...on, androidAuto: false });
      expect(app['meta-data']).toHaveLength(1);
      expect(marker(app['meta-data'], 'com.google.android.gms.car.application')).toBe('remove');
    });

    it('takes an earlier removal back out when the car is turned on again', () => {
      const { manifest, app } = setUp();
      const off = { carplay: true, androidAuto: false, automotive: false };
      plugin.configureCarDeclarations(manifest, app, off);
      plugin.configureCarDeclarations(manifest, app, off);
      expect(app['meta-data']).toHaveLength(2);
      plugin.configureCarDeclarations(manifest, app, on);
      expect(app['meta-data']).toBeUndefined();
      expect(app.service[0]['meta-data']).toBeUndefined();
    });
  });
});
