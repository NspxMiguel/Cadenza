class Cadenza < Formula
  desc "Native macOS client for Apple Music Classical"
  homepage "https://github.com/NspxMiguel/Cadenza"
  head "https://github.com/NspxMiguel/Cadenza.git", branch: "main"
  license "MIT"

  # Command Line Tools are enough — the app deliberately avoids anything that
  # would require a full Xcode install.
  depends_on xcode: :build
  depends_on :macos => :sequoia

  def install
    # --disable-sandbox: SwiftPM writes to .build, which Homebrew's sandbox
    # would otherwise deny.
    system "swift", "build",
           "--configuration", "release",
           "--disable-sandbox",
           "--product", "Cadenza"

    app = buildpath/"Cadenza.app"
    (app/"Contents/MacOS").mkpath
    (app/"Contents/Resources").mkpath

    bin_path = Utils.safe_popen_read("swift", "build", "-c", "release",
                                     "--disable-sandbox", "--show-bin-path").strip
    cp "#{bin_path}/Cadenza", app/"Contents/MacOS/Cadenza"
    cp buildpath/"Resources/Cadenza.icns", app/"Contents/Resources/Cadenza.icns"

    (app/"Contents/Info.plist").write <<~PLIST
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
          <key>CFBundleExecutable</key><string>Cadenza</string>
          <key>CFBundleIdentifier</key><string>com.miguel.cadenza</string>
          <key>CFBundleName</key><string>Cadenza</string>
          <key>CFBundleIconFile</key><string>Cadenza</string>
          <key>CFBundleDisplayName</key><string>Cadenza</string>
          <key>CFBundlePackageType</key><string>APPL</string>
          <key>CFBundleShortVersionString</key><string>#{version}</string>
          <key>CFBundleVersion</key><string>#{version}</string>
          <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
          <key>LSMinimumSystemVersion</key><string>15.0</string>
          <key>NSHighResolutionCapable</key><true/>
    <!-- So searching for what the app is finds it. -->
    <key>CFBundleSpotlightKeywords</key>
    <array>
        <string>classical</string><string>clássica</string>
        <string>apple music classical</string><string>apple music</string>
        <string>música clássica</string><string>partitura</string>
        <string>ópera</string><string>concerto</string><string>sinfonia</string>
    </array>
          <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
          <key>NSAppleMusicUsageDescription</key>
          <string>Cadenza precisa acessar o Apple Music para tocar o catálogo classical.</string>
      </dict>
      </plist>
    PLIST

    # Ad-hoc signature, applied on this machine. Because the binary is compiled
    # locally rather than downloaded, Gatekeeper has no quarantine attribute to
    # complain about — no "unidentified developer" prompt.
    system "codesign", "--force", "--deep", "--sign", "-", app

    prefix.install app
  end

  def post_install
    # Homebrew keeps everything under its prefix; a link in ~/Applications makes
    # the app reachable from Spotlight and the Dock.
    applications = Pathname.new(Dir.home)/"Applications"
    applications.mkpath
    link = applications/"Cadenza.app"
    link.unlink if link.symlink? || link.exist?
    link.make_symlink(prefix/"Cadenza.app")
  end

  def caveats
    <<~EOS
      Cadenza foi compilado nesta máquina e assinado localmente, então o
      Gatekeeper não exibe aviso de desenvolvedor não identificado.

      O app está em:
        #{prefix}/Cadenza.app
      e com um link em ~/Applications.

      Na primeira execução, entre com seu Apple ID para o Cadenza obter as
      credenciais do catálogo.

      Reprodução padrão: 256 kbps AAC. Lossless e Spatial Audio exigem a
      entitlement MusicKit, que depende do Apple Developer Program pago —
      veja docs/lossless.md para compilar com a sua conta.
    EOS
  end

  test do
    assert_predicate prefix/"Cadenza.app/Contents/MacOS/Cadenza", :exist?
  end
end
