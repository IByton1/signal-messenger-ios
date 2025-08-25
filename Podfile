platform :ios, '15.0'
use_frameworks!

LIBSIGNAL_TAG      = 'v0.77.0'
LIBSIGNAL_ARCHIVE  = 'libsignal-client-ios-build-v0.77.0.tar.gz'
LIBSIGNAL_CHECKSUM = '5f866e959280f1f6dffaaf20a1ef3360eb2497acf41cd094aba9b2bf902f1b1f'

target 'chat' do
  pod 'LibSignalClient', git: 'https://github.com/signalapp/libsignal.git', tag: LIBSIGNAL_TAG
  pod 'SignalCoreKit',   git: 'https://github.com/signalapp/SignalCoreKit.git'
  pod 'KeychainAccess'
  pod 'GRDB.swift/SQLCipher'
end

post_install do |installer|
  installer.pods_project.targets.each do |t|
    t.build_configurations.each do |config|
      # iOS-Deployment-Target angleichen
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.0'

      # >>> Entscheidend: Build Settings fürs Run-Script bereitstellen
      if t.name == 'LibSignalClient'
        config.build_settings['LIBSIGNAL_FFI_PREBUILD_ARCHIVE']  = LIBSIGNAL_ARCHIVE
        config.build_settings['LIBSIGNAL_FFI_PREBUILD_CHECKSUM'] = LIBSIGNAL_CHECKSUM
      end
    end
  end

  # (Optional, aber empfehlenswert) rsync-Tempfiles in erlaubtes Verzeichnis legen
  installer.pods_project.targets.each do |t|
    t.build_phases.each do |phase|
      next unless phase.respond_to?(:name) && phase.name == '[CP] Embed Pods Frameworks'
      phase.shellScript = phase.shellScript.gsub(
        'rsync --delete -av',
        'rsync --delete -av --temp-dir="$TARGET_TEMP_DIR"'
      )
    end
  end
end
