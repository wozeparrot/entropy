{
  description = "chargino: A nix + nelua 3d/vr experience framework";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-mozilla.url = "github:mozilla/nixpkgs-mozilla";

    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, nixpkgs-mozilla, flake-utils }:
    let
      inherit (nixpkgs.lib) recursiveUpdate recurseIntoAttrs optional;
      inherit (flake-utils.lib) eachSystem flattenTree;
    in
    # supported systems that we can run builds from
    eachSystem [
      "x86_64-linux"
    ]
      (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ nixpkgs-mozilla.overlay ];
          };
        in
        rec {
          packages =
            let
              linuxPkgs = import nixpkgs {
                inherit system;
                crossSystem = if (system != "x86_64-linux") then { config = "x86_64-linux"; } else null;
                overlays = [ nixpkgs-mozilla.overlay ];
              };
              windowsPkgs = import nixpkgs {
                inherit system;
                crossSystem = { config = "x86_64-w64-mingw32"; };
                overlays = [ nixpkgs-mozilla.overlay ];
              };
            in
            flattenTree rec {
              game =
                let
                  nelua_modules = [
                    glfw-nelua
                    glfwnative-nelua
                    wgpu-nelua
                  ];

                  baseDrv = extraModules: {
                    pname = "game";
                    version = "0.1.0";

                    src = ./.;

                    nativeBuildInputs = [
                      nelua
                    ] ++ nelua_modules;

                    # build NELUA_PATH so that nelua can find all of our modules
                    preBuild =
                      let
                        nelua_path = "${nelua}/lib/nelua/lib/?.nelua;" + (nixpkgs.lib.foldr (module: path: "${module}/nelua/?.nelua;" + path) ";" (nelua_modules ++ extraModules));
                      in
                      ''
                        export HOME=$TMPDIR
                        export NELUA_PATH="${nelua_path}"
                      '';

                    # add all the nelua modules to the include path because they may contain headers
                    CFLAGS = builtins.map (module: "-I${module}/include") (nelua_modules ++ extraModules);

                    installPhase = ''
                      mkdir -p $out/bin
                      nelua --cc $CC game.nelua -o $out/bin/game

                      runHook postInstall
                    '';
                  };
                in
                recurseIntoAttrs {
                  linux = linuxPkgs.stdenv.mkDerivation (recursiveUpdate (baseDrv [ ]) {
                    buildInputs = with linuxPkgs; [
                      xorg.libX11
                      xorg.libXrandr
                    ] ++ [
                      glfw.linux
                      wgpu-native.linux
                    ];
                  });
                  windows = windowsPkgs.stdenv.mkDerivation (recursiveUpdate (baseDrv [ windows-nelua ]) {
                    buildInputs = with windowsPkgs; [
                    ] ++ [
                      glfw.windows
                      wgpu-native.windows
                    ];

                    postInstall = ''
                      cp ${glfw.windows}/bin/glfw3.dll $out/bin
                      cp ${wgpu-native.windows}/bin/wgpu_native.dll $out/bin
                    '';
                  });
                };

              # ===== REQUIRED LIBS/BUILD STUFF BELOW =====
              glfw =
                let
                  baseDrv = {
                    pname = "glfw";
                    version = "3.3.7";

                    src = pkgs.fetchFromGitHub {
                      owner = "glfw";
                      repo = "GLFW";
                      rev = baseDrv.version;
                      sha256 = "sha256-aWwt6FRq/ofQmZAeavDa8inrJfrPxb8iyo1XYdQsrKc=";
                    };

                    nativeBuildInputs = with pkgs; [ cmake ];

                    cmakeFlags = [ "-DBUILD_SHARED_LIBS=ON" "-DGLFW_BUILD_EXAMPLES=OFF" "-DGLFW_BUILD_TESTS=OFF" ];
                  };
                in
                recurseIntoAttrs {
                  linux = linuxPkgs.stdenv.mkDerivation (recursiveUpdate baseDrv {
                    patches =
                      let
                        x11_patch = pkgs.writeText "x11.patch" ''
                          diff --git a/src/CMakeLists.txt b/src/CMakeLists.txt
                          index a0be580e..ba143851 100644
                          --- a/src/CMakeLists.txt
                          +++ b/src/CMakeLists.txt
                          @@ -219,6 +219,13 @@ if (GLFW_BUILD_X11)
                               if (NOT X11_Xshape_INCLUDE_PATH)
                                   message(FATAL_ERROR "X Shape headers not found; install libxext development package")
                               endif()
                          +
                          +    target_link_libraries(glfw PRIVATE ''\${X11_Xrandr_LIB}
                          +                                       ''\${X11_Xinerama_LIB}
                          +                                       ''\${X11_Xkb_LIB}
                          +                                       ''\${X11_Xcursor_LIB}
                          +                                       ''\${X11_Xi_LIB}
                          +                                       ''\${X11_Xshape_LIB})
                           endif()

                           if (UNIX AND NOT APPLE)
                        '';
                      in
                      [ x11_patch ];

                    buildInputs = with linuxPkgs; [ xorg.libX11 xorg.libXrandr xorg.libXinerama xorg.libXcursor xorg.libXi xorg.libXext ];
                  });
                  windows = windowsPkgs.stdenv.mkDerivation (recursiveUpdate baseDrv {
                    # this is needed because zig looks for .lib files to link for when compiling for windows
                    postInstall = ''
                      ln -fs $out/lib/libglfw3dll.a $out/lib/glfw3.lib
                    '';
                  });
                };

              wgpu-native =
                let
                  baseDrv = {
                    pname = "wgpu-native";
                    version = "0.12.0.1";

                    src = pkgs.fetchFromGitHub {
                      owner = "gfx-rs";
                      repo = baseDrv.pname;
                      rev = "v${baseDrv.version}";
                      fetchSubmodules = true;
                      sha256 = "sha256-6qcE8sKv2qhRTYN2qZQzRCosYD4rfsAicwLvDzh+c4Y=";
                    };

                    cargoSha256 = "sha256-ZU9gBgnwpjiLOt2b4AoxNXX4eQEoJP/O15fOjNRZXI4=";

                    nativeBuildInputs = with pkgs; [
                      rustPlatform.bindgenHook
                    ];

                    postInstall = ''
                      mkdir $out/include

                      cp ffi/webgpu-headers/webgpu.h $out/include
                      cp ffi/wgpu.h $out/include
                      sed -i -e 's/#include "webgpu-headers.*/#include <webgpu.h>/' $out/include/wgpu.h
                    '';
                  };
                in
                recurseIntoAttrs {
                  linux = linuxPkgs.rustPlatform.buildRustPackage (recursiveUpdate baseDrv { });
                  windows =
                    let
                      rustPlatform =
                        let
                          rustStable = (pkgs.rustChannelOf {
                            channel = "1.60.0";
                            sha256 = "sha256-otgm+7nEl94JG/B+TYhWseZsHV1voGcBsW/lOD2/68g=";
                          }).rust.override {
                            targets = [
                              "x86_64-pc-windows-gnu"
                            ];
                          };
                        in
                        windowsPkgs.makeRustPlatform {
                          rustc = rustStable;
                          cargo = rustStable;
                        };
                    in
                    rustPlatform.buildRustPackage (recursiveUpdate baseDrv {
                      # this is needed because zig looks for .lib files to link for when compiling for windows
                      postInstall = ''
                        ln -fs $out/lib/libwgpu_native.dll.a $out/lib/wgpu_native.lib
                      '';
                    });
                };

              # ===== NELUA =====
              nelua =
                pkgs.stdenv.mkDerivation rec {
                  pname = "nelua";
                  version = "7e02f26b84e4ebbd0966b876d960b9cda6583fa2";

                  src = pkgs.fetchFromGitHub {
                    owner = "edubart";
                    repo = "nelua-lang";
                    rev = version;
                    sha256 = "sha256-h5fyOgP+dEUY+KTyan0acCaz0/GzQ/4ld60zK5+rIR0=";
                  };

                  patchPhase = ''
                    # patch out hardcoded CC
                    sed -i -e 's/CC=.*//' Makefile
                  '';

                  makeFlags = [ "PREFIX=$(out)" ];
                };

              nelua-decl =
                pkgs.stdenv.mkDerivation rec {
                  pname = "nelua-decl";
                  version = "63b4b40a582d9e6ceb697d6e58220e164ffd91fc";

                  src = pkgs.fetchFromGitHub {
                    owner = "edubart";
                    repo = "nelua-decl";
                    rev = version;
                    fetchSubmodules = true;
                    sha256 = "sha256-Kh1HeTz4AFCoZeeIbrxtLR5bGJtSDECjxTZImIH5kPg=";
                  };

                  nativeBuildInputs = with pkgs; [
                    pkg-config
                  ];

                  buildInputs = with pkgs; [
                    gmp
                    lua
                  ];

                  buildPhase = ''
                    make -C gcc-lua
                  '';

                  installPhase = ''
                    mkdir -p $out/lib
                    cp gcc-lua/gcc/gcclua.so $out/lib/
                    cp *.lua $out/lib/

                    mkdir -p $out/nelua
                    shopt -s globstar
                    for f in **/*.nelua; do
                      cp "$f" $out/nelua
                    done
                  '';
                };

              # ===== NELUA BINDINGS =====
              glfw-nelua =
                pkgs.runCommand "glfw-nelua" { } ''
                  mkdir -p $out/nelua
                  cp ${nelua-decl}/nelua/glfw.nelua $out/nelua
                  sed -i -e 's/linklib .GL.//' $out/nelua/glfw.nelua
                  sed -i -e 's/linklib .opengl32.//' $out/nelua/glfw.nelua
                  sed -i -e '1s;^;## cdefine "GLFW_INCLUDE_NONE"\n;' $out/nelua/glfw.nelua
                '';

              glfwnative-nelua =
                let
                  glfwnative_nelua = pkgs.writeText "glfwnative.nelua" ''
                    ##[[
                    if ccinfo.is_windows then
                      cdefine 'GLFW_EXPOSE_NATIVE_WIN32'
                    else
                      cdefine 'GLFW_EXPOSE_NATIVE_X11'
                    end
                    cinclude '<GLFW/glfw3native.h>'
                    ]]

                    ## if ccinfo.is_windows then
                      require 'windows'

                      global function glfwGetWin32Adapter(monitor: *GLFWmonitor): cstring <cimport,nodecl> end
                      global function glfwGetWin32Monitor(monitor: *GLFWmonitor): cstring <cimport,nodecl> end
                      global function glfwGetWin32Window(window: *GLFWwindow): HWND <cimport,nodecl> end
                    ## else
                      global Display: type <cimport,nodecl> = @record{}

                      global function glfwGetX11Display(): *Display <cimport,nodecl> end
                      global function glfwGetX11Adapter(monitor: *GLFWmonitor): culong <cimport,nodecl> end
                      global function glfwGetX11Monitor(monitor: *GLFWmonitor): culong <cimport,nodecl> end
                      global function glfwGetX11Window(window: *GLFWwindow): culong <cimport,nodecl> end
                      global function glfwSetX11SelectionString(string: cstring): void <cimport,nodecl> end
                      global function glfwGetX11SelectionString(): cstring <cimport,nodecl> end
                    ## end
                  '';
                in
                pkgs.runCommand "glfwnative-nelua" { } ''
                  mkdir -p $out/nelua
                  cp ${glfwnative_nelua} $out/nelua/glfwnative.nelua
                '';

              wgpu-nelua =
                let
                  wgpu_lua = pkgs.writeText "wgpu.lua" ''
                    local nldecl = require 'nldecl'

                    nldecl.include_names = {
                      '^WGPU',
                      '^wgpu',
                    }

                    nldecl.prepend_code = [=[
                    ##[[
                    cinclude '<webgpu.h>'
                    cinclude '<wgpu.h>'
                    linklib 'wgpu_native'
                    ]]
                    ]=]
                  '';
                  wgpu_c = pkgs.writeText "wgpu.c" ''
                    #include "webgpu.h"
                    #include "wgpu.h"
                  '';
                in
                pkgs.runCommandCC "wgpu-nelua" { } ''
                  cp ${wgpu-native.linux}/include/*.h .
                  cp ${wgpu_lua} wgpu.lua
                  cp ${wgpu_c} wgpu.c

                  mkdir -p $out/nelua/
                  export LUA_PATH="${nelua-decl}/lib/?.lua;;"
                  gcc -fplugin=${nelua-decl}/lib/gcclua.so -fplugin-arg-gcclua-script=wgpu.lua -S wgpu.c -I. > $out/nelua/wgpu.nelua

                  mkdir -p $out/include
                  cp *.h $out/include
                '';

              windows-nelua =
                pkgs.runCommand "windows-nelua" { } ''
                  mkdir -p $out/nelua
                  cp ${nelua-decl}/nelua/windows.nelua $out/nelua
                '';
            };

          devShell =
            pkgs.mkShell
              {
                nativeBuildInputs = with pkgs;
                  [
                    gcc
                    xorg.libX11
                    xorg.libXrandr
                    wine64
                  ] ++ [
                    packages.nelua
                    packages."glfw/linux"
                    packages."wgpu-native/linux"
                  ];

                LD_LIBRARY_PATH = [ "${pkgs.vulkan-loader}/lib" ];
              };
        }
      );
}