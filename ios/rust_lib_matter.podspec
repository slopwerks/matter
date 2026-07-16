# Compute absolute path to framework under rust/target/ (gitignored)
rust_target_dir = File.expand_path('../../rust/target', __FILE__)
framework_path = File.join(rust_target_dir, 'rust_lib_matter.framework')

Pod::Spec.new do |s|
  s.name             = 'rust_lib_matter'
  s.version          = '0.1.4'
  s.summary          = 'Rust core library for Matter'
  s.homepage         = 'https://github.com/slopwerks/matter'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Akatsukiro' => 'aka@bep.ink' }
  s.source           = { :path => '.' }
  s.platforms        = { :osx => '10.15', :ios => '13.0' }

  s.source_files = []
  s.preserve_paths = 'rust_lib_matter.podspec'

  # Create the versioned framework skeleton at pod install time.
  # vendored_frameworks needs the stub to exist (Info.plist + symlinks).
  # The actual binary is added by script_phase during the Xcode build.
  s.prepare_command = <<~CMD
    mkdir -p #{framework_path}
    python3 -c "import plistlib; plistlib.dump({'CFBundleDevelopmentRegion':'en','CFBundleExecutable':'rust_lib_matter','CFBundleIdentifier':'moe.aks.matter.rust-lib-matter','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'rust_lib_matter','CFBundlePackageType':'FMWK','CFBundleShortVersionString':'1.0','CFBundleVersion':'1'}, open('#{File.join(framework_path, 'Info.plist')}', 'wb'))"
  CMD
end
