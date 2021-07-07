{ stdenv, buildPackages, lib
, fetchurl, fetchpatch, fetchFromSavannah, fetchFromGitHub
, zlib, openssl, gdbm, ncurses, readline, groff, libyaml, libffi, jemalloc, autoreconfHook, bison
, autoconf, libiconv, libobjc, libunwind, Foundation
, buildEnv, bundler, bundix
, makeWrapper, buildRubyGem, defaultGemConfig, removeReferencesTo
} @ args:

let
  op = lib.optional;
  ops = lib.optionals;
  opString = lib.optionalString;
  patchSet = import ./rvm-patchsets.nix { inherit fetchFromGitHub; };
  config = import ./config.nix { inherit fetchFromSavannah; };
  rubygems = import ./rubygems { inherit stdenv lib fetchurl; };

  # Contains the ruby version heuristics
  rubyVersion = import ./ruby-version.nix { inherit lib; };

  # Needed during postInstall
  buildRuby =
    if stdenv.hostPlatform == stdenv.buildPlatform
    then "$out/bin/ruby"
    else "${buildPackages.ruby}/bin/ruby";

  generic = { version, sha256 }: let
    ver = version;
    tag = ver.gitTag;
    atLeast27 = lib.versionAtLeast ver.majMin "2.7";
    atLeast30 = lib.versionAtLeast ver.majMin "3.0";
    baseruby = self.override {
      useRailsExpress = false;
      docSupport = false;
      rubygemsSupport = false;
    };
    self = lib.makeOverridable (
      { stdenv, buildPackages, lib
      , fetchurl, fetchpatch, fetchFromSavannah, fetchFromGitHub
      , useRailsExpress ? true
      , rubygemsSupport ? true
      , zlib, zlibSupport ? true
      , openssl, opensslSupport ? true
      , gdbm, gdbmSupport ? true
      , ncurses, readline, cursesSupport ? true
      , groff, docSupport ? true
      , libyaml, yamlSupport ? true
      , libffi, fiddleSupport ? true
      , jemalloc, jemallocSupport ? false
      # By default, ruby has 3 observed references to stdenv.cc:
      #
      # - If you run:
      #     ruby -e "puts RbConfig::CONFIG['configure_args']"
      # - In:
      #     $out/${passthru.libPath}/${stdenv.hostPlatform.system}/rbconfig.rb
      #   Or (usually):
      #     $(nix-build -A ruby)/lib/ruby/2.6.0/x86_64-linux/rbconfig.rb
      # - In $out/lib/libruby.so and/or $out/lib/libruby.dylib
      , removeReferencesTo, jitSupport ? false
      , autoreconfHook, bison, autoconf
      , buildEnv, bundler, bundix
      , libiconv, libobjc, libunwind, Foundation
      , makeWrapper, buildRubyGem, defaultGemConfig
      }:
      stdenv.mkDerivation rec {
        pname = "ruby";
        inherit version;

        src = if useRailsExpress then fetchFromGitHub {
          owner  = "ruby";
          repo   = "ruby";
          rev    = tag;
          sha256 = sha256.git;
        } else fetchurl {
          url = "https://cache.ruby-lang.org/pub/ruby/${ver.majMin}/ruby-${ver}.tar.gz";
          sha256 = sha256.src;
        };

        # Have `configure' avoid `/usr/bin/nroff' in non-chroot builds.
        NROFF = if docSupport then "${groff}/bin/nroff" else null;

        outputs = [ "out" ] ++ lib.optional docSupport "devdoc";

        nativeBuildInputs = [ autoreconfHook bison ]
          ++ (op docSupport groff)
          ++ op (stdenv.buildPlatform != stdenv.hostPlatform) buildPackages.ruby;
        buildInputs = [ autoconf ]
          ++ (op fiddleSupport libffi)
          ++ (ops cursesSupport [ ncurses readline ])
          ++ (op zlibSupport zlib)
          ++ (op opensslSupport openssl)
          ++ (op gdbmSupport gdbm)
          ++ (op yamlSupport libyaml)
          ++ (op jemallocSupport jemalloc)
          # Looks like ruby fails to build on darwin without readline even if curses
          # support is not enabled, so add readline to the build inputs if curses
          # support is disabled (if it's enabled, we already have it) and we're
          # running on darwin
          ++ op (!cursesSupport && stdenv.isDarwin) readline
          ++ ops stdenv.isDarwin [ libiconv libobjc libunwind Foundation ];

        enableParallelBuilding = true;

        patches =
          (import ./patchsets.nix {
            inherit patchSet useRailsExpress ops fetchpatch;
            patchLevel = ver.patchLevel;
          }).${ver.majMinTiny}
          ++ op atLeast27 ./do-not-regenerate-revision.h.patch
          ++ op (atLeast30 && useRailsExpress) ./do-not-update-gems-baseruby.patch
          # Ruby prior to 3.0 has a bug the installer (tools/rbinstall.rb) but
          # the resulting error was swallowed. Newer rubygems no longer swallows
          # this error. We upgrade rubygems when rubygemsSupport is enabled, so
          # we have to fix this bug to prevent the install step from failing.
          # See https://github.com/ruby/ruby/pull/2930
          ++ op (!atLeast30 && rubygemsSupport)
            (fetchpatch {
              url = "https://github.com/ruby/ruby/commit/261d8dd20afd26feb05f00a560abd99227269c1c.patch";
              sha256 = "0wrii25cxcz2v8bgkrf7ibcanjlxwclzhayin578bf0qydxdm9qy";
            });

        postUnpack = opString rubygemsSupport ''
          rm -rf $sourceRoot/{lib,test}/rubygems*
          cp -r ${rubygems}/lib/rubygems* $sourceRoot/lib
          cp -r ${rubygems}/test/rubygems $sourceRoot/test
        '';

        postPatch = ''
          sed -i configure.ac -e '/config.guess/d'
          cp --remove-destination ${config}/config.guess tool/
          cp --remove-destination ${config}/config.sub tool/
        '' + opString (!atLeast30) ''
          # Make the build reproducible for ruby <= 2.7
          # See https://github.com/ruby/io-console/commit/679a941d05d869f5e575730f6581c027203b7b26#diff-d8422f096931c58d4463e2489f62a228b0f24f0492950ba88c8c89a0d741cfe6
          sed -i ext/io/console/io-console.gemspec -e '/s\.date/d'
        '';

        configureFlags = ["--enable-shared" "--enable-pthread" "--with-soname=ruby-${version}"]
          ++ op useRailsExpress "--with-baseruby=${baseruby}/bin/ruby"
          ++ op (!jitSupport) "--disable-jit-support"
          ++ op (!docSupport) "--disable-install-doc"
          ++ op (jemallocSupport) "--with-jemalloc"
          ++ ops stdenv.isDarwin [
            # on darwin, we have /usr/include/tk.h -- so the configure script detects
            # that tk is installed
            "--with-out-ext=tk"
            # on yosemite, "generating encdb.h" will hang for a very long time without this flag
            "--with-setjmp-type=setjmp"
          ]
          ++ op (stdenv.hostPlatform != stdenv.buildPlatform)
             "--with-baseruby=${buildRuby}";

        preConfigure = opString docSupport ''
          configureFlagsArray+=("--with-ridir=$devdoc/share/ri")

          # rdoc creates XDG_DATA_DIR (defaulting to $HOME/.local/share) even if
          # it's not going to be used.
          export HOME=$TMPDIR
        '';

        # fails with "16993 tests, 2229489 assertions, 105 failures, 14 errors, 89 skips"
        # mostly TZ- and patch-related tests
        # TZ- failures are caused by nix sandboxing, I didn't investigate others
        doCheck = false;

        preInstall = ''
          # Ruby installs gems here itself now.
          mkdir -pv "$out/${passthru.gemPath}"
          export GEM_HOME="$out/${passthru.gemPath}"
        '';

        installFlags = lib.optional docSupport "install-doc";
        # Bundler tries to create this directory
        postInstall = ''
          rbConfig=$(find $out/lib/ruby -name rbconfig.rb)
          # Remove unnecessary groff reference from runtime closure, since it's big
          sed -i '/NROFF/d' $rbConfig
          ${
            lib.optionalString (!jitSupport) ''
              # Get rid of the CC runtime dependency
              ${removeReferencesTo}/bin/remove-references-to \
                -t ${stdenv.cc} \
                $out/lib/libruby*
              ${removeReferencesTo}/bin/remove-references-to \
                -t ${stdenv.cc} \
                $rbConfig
              sed -i '/CC_VERSION_MESSAGE/d' $rbConfig
            ''
          }
          # Bundler tries to create this directory
          mkdir -p $out/nix-support
          cat > $out/nix-support/setup-hook <<EOF
          addGemPath() {
            addToSearchPath GEM_PATH \$1/${passthru.gemPath}
          }
          addRubyLibPath() {
            addToSearchPath RUBYLIB \$1/lib/ruby/site_ruby
            addToSearchPath RUBYLIB \$1/lib/ruby/site_ruby/${ver.libDir}
            addToSearchPath RUBYLIB \$1/lib/ruby/site_ruby/${ver.libDir}/${stdenv.hostPlatform.system}
          }

          addEnvHooks "$hostOffset" addGemPath
          addEnvHooks "$hostOffset" addRubyLibPath
          EOF
        '' + opString docSupport ''
          # Prevent the docs from being included in the closure
          sed -i "s|\$(DESTDIR)$devdoc|\$(datarootdir)/\$(RI_BASE_NAME)|" $rbConfig
          sed -i "s|'--with-ridir=$devdoc/share/ri'||" $rbConfig

          # Add rbconfig shim so ri can find docs
          mkdir -p $devdoc/lib/ruby/site_ruby
          cp ${./rbconfig.rb} $devdoc/lib/ruby/site_ruby/rbconfig.rb
        '' + opString useRailsExpress ''
          # Prevent the baseruby from being included in the closure.
          sed -i '/^  CONFIG\["BASERUBY"\]/d' $rbConfig
          sed -i "s|'--with-baseruby=${baseruby}/bin/ruby'||" $rbConfig
        '';

        disallowedRequisites = op (!jitSupport) stdenv.cc.cc;

        meta = with lib; {
          description = "The Ruby language";
          homepage    = "http://www.ruby-lang.org/en/";
          license     = licenses.ruby;
          maintainers = with maintainers; [ vrthra manveru marsam ];
          platforms   = platforms.all;
        };

        passthru = rec {
          version = ver;
          rubyEngine = "ruby";
          baseRuby = baseruby;
          libPath = "lib/${rubyEngine}/${ver.libDir}";
          gemPath = "lib/${rubyEngine}/gems/${ver.libDir}";
          devEnv = import ./dev.nix {
            inherit buildEnv bundler bundix;
            ruby = self;
          };

          inherit (import ../../ruby-modules/with-packages {
            inherit lib stdenv makeWrapper buildRubyGem buildEnv;
            gemConfig = defaultGemConfig;
            ruby = self;
          }) withPackages gems;

          # deprecated 2016-09-21
          majorVersion = ver.major;
          minorVersion = ver.minor;
          teenyVersion = ver.tiny;
          patchLevel = ver.patchLevel;
        };
      }
    ) args; in self;

in {
  ruby_2_6 = generic {
    version = rubyVersion "2" "6" "8" "";
    sha256 = {
      src = "0vfam28ifl6h2wxi6p70j0hm3f1pvsp432hf75m5j25wfy2vf1qq";
      git = "0rc3n6sk8632r0libpv8jwslc7852hgk64rvbdrspc9razjwx21c";
    };
  };

  ruby_2_7 = generic {
    version = rubyVersion "2" "7" "4" "";
    sha256 = {
      src = "0nxwkxh7snmjqf787qsp4i33mxd1rbf9yzyfiky5k230i680jhrh";
      git = "1prsrqwkla4k5japlm54k0j700j4824rg8z8kpswr9r3swrmrf5p";
    };
  };

  ruby_3_0 = generic {
    version = rubyVersion "3" "0" "1" "";
    sha256 = {
      src = "09vpnxxcxc46qv40xbxr9xkdpbgb0imdy25l2vpsxxlr47djb61n";
      git = "0vricyhnnczcbsgvz65pdhi9yx1i34zarbjlc5y5mcmj01y9r7ar";
    };
  };
}
