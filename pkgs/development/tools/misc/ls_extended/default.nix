{ stdenv, fetchFromGitHub, makeWrapper }:

stdenv.mkDerivation rec {
  name = "ls_extended-${version}";
  version = "1.1.0";

  src = fetchFromGitHub {
    owner = "Electrux";
    repo = "ls_extended";
    rev = "v${version}";
    sha256 = "1nv7vvy7sqnvy30cbxmrvckd2932v5iixpn48qf5pvlxnwwgi6m2";
  };

  buildPhase = "bash ./build.sh";
  installPhase = ''
    mkdir -p $out/bin
    install -m 755 bin/ls_extended $out/bin/ls_extended
  '';

  meta = with stdenv; {
    homepage = https://github.com/Electrux/ls_extended;
    description = "Ls with coloring and icons";
    license = lib.licenses.bsd3;
    maintainers = with maintainers; [ CrazedProgrammer ];
  };
}
