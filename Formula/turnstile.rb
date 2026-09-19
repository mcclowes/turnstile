class Turnstile < Formula
  desc "Machine-wide, memory-aware gate for builds and tests on macOS"
  homepage "https://github.com/mcclowes/turnstile"
  url "https://github.com/mcclowes/turnstile/releases/download/v0.3.0/turnstile-0.3.0-macos.tar.gz"
  sha256 "9af01fa9bc2e26ba3162470451ebcfe254dbe98b6fe52c74d2d24c5efb0f9e24"
  version "0.3.0"
  license "MIT"

  depends_on :macos

  def install
    bin.install "turnstile"
  end

  def caveats
    <<~EOS
      Put the shims on PATH (once per machine), then check the install:
        turnstile init
        turnstile doctor
      Upgrades carry over; there's no need to rerun init.
    EOS
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/turnstile --version").strip
  end
end
