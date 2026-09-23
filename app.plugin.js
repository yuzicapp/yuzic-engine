const {
  withInfoPlist,
  withAndroidManifest,
  AndroidConfig,
} = require('@expo/config-plugins');

/**
 * Expo config plugin for yuzic-engine.
 *
 * Everything here is native configuration the engine cannot grant itself. An
 * audio app that does not declare these does not fail loudly — it plays fine
 * until the screen locks, and then stops. That is the worst kind of missing
 * config: invisible in every test that keeps the app in the foreground.
 *
 * Worth knowing for yuzic specifically: it commits its `ios/` and `android/`
 * directories, so config plugins only take effect on a prebuild. The
 * Info.plist entry is already present there today — but it was put there by
 * @rntp/player, and it leaves with it. This plugin is what replaces that, and
 * until a prebuild happens the existing entry has to stay.
 *
 * Options, all defaulting to true so that a host listing the plugin with no
 * options keeps every car surface it had:
 *
 *   ["yuzic-engine", { "carplay": false, "androidAuto": false, "automotive": false }]
 *
 * - `carplay: false` leaves out the CarPlay scene.
 * - `androidAuto: false` and `automotive: false` remove the Android car
 *   declarations. Those live in the library's own manifest, so that they
 *   reach a host that commits its `android/` directory without a prebuild,
 *   and turning one off therefore writes a `tools:node="remove"` marker into
 *   the host's manifest rather than leaving something out. The marker only
 *   lands on a prebuild.
 */

/** Every option on unless the host turned it off by name. */
function resolveOptions(props) {
  const options = props ?? {};
  return {
    carplay: options.carplay !== false,
    androidAuto: options.androidAuto !== false,
    automotive: options.automotive !== false,
  };
}

/** iOS: keep playing when the screen locks. Pure, over the plist object. */
function addBackgroundAudio(infoPlist) {
  const modes = infoPlist.UIBackgroundModes ?? [];
  if (!modes.includes('audio')) {
    infoPlist.UIBackgroundModes = [...modes, 'audio'];
  }
  return infoPlist;
}

/**
 * iOS: tell the system this app has a CarPlay screen, and which class draws it.
 *
 * Without this entry CarPlay never constructs the scene delegate, and the app
 * simply does not appear on the car's home screen — no error, no log, nothing
 * to search for. The class name is a *string* here and `@objc`-pinned on the
 * Swift side, because Swift's mangled name is not what the system looks up.
 *
 * The `com.apple.developer.carplay-audio` entitlement is a separate matter and
 * deliberately not written here: it has to be granted by Apple per app, and a
 * plugin that fabricated it would produce a build that fails to sign with a
 * far less obvious message than "you do not have this entitlement".
 */
function addCarPlayScene(infoPlist) {
  const manifest = infoPlist.UIApplicationSceneManifest ?? {};
  const roles = manifest.UISceneConfigurations ?? {};
  const carPlay = roles.CPTemplateApplicationSceneSessionRoleApplication ?? [];

  const name = 'YuzicEngineCarPlay';
  if (!carPlay.some(scene => scene.UISceneConfigurationName === name)) {
    carPlay.push({
      UISceneConfigurationName: name,
      UISceneDelegateClassName: 'YuzicCarPlaySceneDelegate',
    });
  }

  roles.CPTemplateApplicationSceneSessionRoleApplication = carPlay;
  manifest.UISceneConfigurations = roles;
  infoPlist.UIApplicationSceneManifest = manifest;
  return infoPlist;
}

/**
 * iOS: take this plugin's CarPlay scene back out, for a host that turned
 * CarPlay off after a prebuild had already written it. Scenes the host
 * declared itself are left alone.
 */
function removeCarPlayScene(infoPlist) {
  const roles = infoPlist.UIApplicationSceneManifest?.UISceneConfigurations;
  const carPlay = roles?.CPTemplateApplicationSceneSessionRoleApplication;
  if (!carPlay) return infoPlist;
  const kept = carPlay.filter(scene => scene.UISceneConfigurationName !== 'YuzicEngineCarPlay');
  if (kept.length) {
    roles.CPTemplateApplicationSceneSessionRoleApplication = kept;
  } else {
    delete roles.CPTemplateApplicationSceneSessionRoleApplication;
  }
  return infoPlist;
}

function withBackgroundAudio(config, options) {
  return withInfoPlist(config, config => {
    const plist = addBackgroundAudio(config.modResults);
    config.modResults = options.carplay ? addCarPlayScene(plist) : removeCarPlayScene(plist);
    return config;
  });
}

/**
 * Android: a foreground service, and permission to run one.
 *
 * `FOREGROUND_SERVICE_MEDIA_PLAYBACK` is separate from `FOREGROUND_SERVICE` and
 * required from API 34 — without it the service throws on start, on exactly
 * the newer devices least likely to be tested against.
 */
function addPlaybackService(manifest, application) {

    manifest.manifest['uses-permission'] = manifest.manifest['uses-permission'] ?? [];
    const permissions = [
      'android.permission.FOREGROUND_SERVICE',
      'android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK',
      'android.permission.WAKE_LOCK',
      'android.permission.INTERNET',
      'android.permission.POST_NOTIFICATIONS',
    ];
    for (const name of permissions) {
      const already = manifest.manifest['uses-permission'].some(
        entry => entry.$?.['android:name'] === name
      );
      if (!already) {
        manifest.manifest['uses-permission'].push({ $: { 'android:name': name } });
      }
    }

    application.service = application.service ?? [];
    const serviceName = 'dev.yuzic.engine.PlaybackService';
    const already = application.service.some(
      entry => entry.$?.['android:name'] === serviceName
    );
    if (!already) {
      application.service.push({
        $: {
          'android:name': serviceName,
          'android:exported': 'true',
          'android:foregroundServiceType': 'mediaPlayback',
        },
        'intent-filter': [
          {
            // Both actions on purpose: head units still resolve media browsers
            // by the legacy one, and dropping it makes the app invisible in
            // some cars while looking correct everywhere else.
            action: [
              { $: { 'android:name': 'androidx.media3.session.MediaLibraryService' } },
              { $: { 'android:name': 'android.media.browse.MediaBrowserService' } },
            ],
          },
        ],
      });
    }

    return manifest;
}

/**
 * Android: opt out of the car declarations the library manifest makes.
 *
 * Android Auto reads one application key. Android Automotive reads another,
 * and also needs the opt-in on the media service, so `automotive: false`
 * removes both of those. A declaration that is on is left to the library
 * manifest, and any removal marker from an earlier run is taken back out.
 *
 * The service and permissions `addPlaybackService` writes are also in the
 * library manifest, with the same attributes, so the merged result is the
 * same either way. They are left in place here: dropping them is only safe
 * once a merged manifest from a host has been compared before and after.
 */
const CAR_KEYS = {
  androidAuto: 'com.google.android.gms.car.application',
  automotive: 'com.android.automotive',
};
const LAUNCHABLE = 'androidx.car.app.launchable';

function setRemoved(entries, name, removed) {
  const others = entries.filter(entry => entry.$?.['android:name'] !== name);
  const own = entries.filter(entry => entry.$?.['android:name'] === name);
  if (removed) return [...others, { $: { 'android:name': name, 'tools:node': 'remove' } }];
  // On: keep a declaration the host wrote itself, drop only a marker.
  return [...others, ...own.filter(entry => entry.$['tools:node'] !== 'remove')];
}

function configureCarDeclarations(manifest, application, options) {
  const anyOff = !options.androidAuto || !options.automotive;
  if (anyOff) AndroidConfig.Manifest.ensureToolsAvailable(manifest);

  let metaData = application['meta-data'] ?? [];
  metaData = setRemoved(metaData, CAR_KEYS.androidAuto, !options.androidAuto);
  metaData = setRemoved(metaData, CAR_KEYS.automotive, !options.automotive);
  if (metaData.length) application['meta-data'] = metaData;
  else delete application['meta-data'];

  const service = (application.service ?? []).find(
    entry => entry.$?.['android:name'] === 'dev.yuzic.engine.PlaybackService'
  );
  if (service) {
    const serviceMetaData = setRemoved(service['meta-data'] ?? [], LAUNCHABLE, !options.automotive);
    if (serviceMetaData.length) service['meta-data'] = serviceMetaData;
    else delete service['meta-data'];
  }
  return manifest;
}

function withPlaybackService(config, options) {
  return withAndroidManifest(config, config => {
    const application = AndroidConfig.Manifest.getMainApplicationOrThrow(config.modResults);
    addPlaybackService(config.modResults, application);
    configureCarDeclarations(config.modResults, application, options);
    return config;
  });
}

module.exports = function withYuzicEngine(config, props) {
  const options = resolveOptions(props);
  return withPlaybackService(withBackgroundAudio(config, options), options);
};

// The two transformations, separately, so they can be tested without standing
// up Expo's whole mod pipeline. A config plugin that is wrong fails silently
// at prebuild — the app just stops when the screen locks — so these are worth
// pinning.
module.exports.addBackgroundAudio = addBackgroundAudio;
module.exports.addCarPlayScene = addCarPlayScene;
module.exports.addPlaybackService = addPlaybackService;
module.exports.removeCarPlayScene = removeCarPlayScene;
module.exports.configureCarDeclarations = configureCarDeclarations;
module.exports.resolveOptions = resolveOptions;
