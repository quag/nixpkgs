{ gcc9Stdenv, lib, stdenv, fetchFromGitHub, cmake, gettext, pkg-config, gpgme, libsolv, openssl, check
, json_c, libmodulemd, libsmartcols, sqlite, librepo, libyaml, rpm }:

gcc9Stdenv.mkDerivation rec {
  pname = "libdnf";
  version = "0.61.1";

  src = fetchFromGitHub {
    owner = "rpm-software-management";
    repo = pname;
    rev = version;
    sha256 = "sha256-ad0Q/8FEaSqsuA6tVC5SB4bTrGJY/8Xb8S8zrsDIyVc=";
  };

  nativeBuildInputs = [
    cmake
    gettext
    pkg-config
  ];

  buildInputs = [
    check
    gpgme
    openssl
    json_c
    libsmartcols
    libyaml
    libmodulemd
  ];

  propagatedBuildInputs = [
    sqlite
    libsolv
    librepo
    rpm
  ];

  # See https://github.com/NixOS/nixpkgs/issues/107430
  prePatch = ''
    cp ${libsolv}/share/cmake/Modules/FindLibSolv.cmake cmake/modules/
  '';

  # See https://github.com/NixOS/nixpkgs/issues/107428
  postPatch = ''
    substituteInPlace CMakeLists.txt \
      --replace "enable_testing()" "" \
      --replace "add_subdirectory(tests)" ""
  '';

  cmakeFlags = [
    "-DWITH_GTKDOC=OFF"
    "-DWITH_HTML=OFF"
    "-DWITH_BINDINGS=OFF"
    "-DWITH_ZCHUNK=OFF"
  ];

  meta = with lib; {
    description = "Package management library.";
    homepage = "https://github.com/rpm-software-management/libdnf";
    license = licenses.gpl2Plus;
    platforms = platforms.linux ++ platforms.darwin;
    maintainers = with maintainers; [ rb2k ];
  };
}
