{
  description = "Stardust: native OpenBW build and test harness";

  inputs.nixpkgs.url = "github:nixos/nixpkgs/nixos-26.05";

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    llvm = pkgs.llvmPackages;

    # StarCraft 1.16.1. Same name and hash as nix-config's pkgs/starcraft-1161,
    # so this resolves to the store path that is already there instead of
    # downloading again.
    starcraftZip = pkgs.fetchurl {
      name = "Starcraft_1161.zip";
      url = "https://davechurchill.ca/starcraft/files/Starcraft_1161.zip";
      hash = "sha256-G58L9bcZxZ7ERWO6Dfg0v8cIczIxXXqeZ7BzEmiukNw=";
    };

    # OpenBW opens Patch_rt.mpq, BrooDat.mpq and StarDat.mpq from the working
    # directory (openbw/data_loading.h), and Linux is case-sensitive: the zip
    # ships them as STARDAT.MPQ, BROODAT.MPQ and patch_rt.mpq.
    scData = pkgs.runCommand "starcraft-mpqs" {nativeBuildInputs = [pkgs.unzip];} ''
      unzip -j ${starcraftZip} STARDAT.MPQ BROODAT.MPQ patch_rt.mpq -d mpq
      mkdir -p $out
      mv mpq/STARDAT.MPQ $out/StarDat.mpq
      mv mpq/BROODAT.MPQ $out/BrooDat.mpq
      mv mpq/patch_rt.mpq $out/Patch_rt.mpq
    '';

    # clang with libc++ rather than libstdc++: upstream develops against Apple's
    # libc++, and the vendored code (BWAPI, nlohmann, Locutus, BOSS) leans on its
    # transitive includes. GCC 15's libstdc++ also #warns on <ciso646>, which
    # nlohmann includes, and -Werror turns that into an error in every file.
    buildTools = [pkgs.cmake pkgs.ninja pkgs.ccache llvm.libcxxStdenv.cc pkgs.git];

    # Shared by the runners: configure once per build type, then build the test
    # binary incrementally. Sets $root and $build.
    buildSnippet = ''
      root=$(git rev-parse --show-toplevel)
      type="''${STARDUST_BUILD_TYPE:-Release}"
      build="''${STARDUST_BUILD_DIR:-$root/build/$type}"

      export CC=clang CXX=clang++
      # The cc-wrapper's hardening flags (_FORTIFY_SOURCE etc.) trip -Werror.
      export NIX_HARDENING_ENABLE=""
      # ccache's default compiler check is mtime+size, and every store path has
      # mtime 1970. Wrappers that inject different flags (e.g. -stdlib=libc++)
      # would otherwise share cache entries and mix C++ ABIs at link time.
      export CCACHE_COMPILERCHECK=content
      # Outside a stdenv shell no setup hook adds libc++'s library directory, so the
      # wrapper's -lc++ has no search path. The cc-wrapper only reads the
      # target-suffixed variable here; its ld-wrapper also turns the -L into an rpath.
      export NIX_LDFLAGS_${llvm.libcxxStdenv.cc.suffixSalt}="-L${llvm.libcxx}/lib"

      if [ ! -f "$build/CMakeCache.txt" ]; then
        cmake -S "$root" -B "$build" -G Ninja \
          -DCMAKE_BUILD_TYPE="$type" \
          -DCMAKE_C_COMPILER_LAUNCHER=ccache \
          -DCMAKE_CXX_COMPILER_LAUNCHER=ccache
      fi
      cmake --build "$build" --target tests
    '';

    # Build, link in the game data and run gtest from the directory the harness
    # expects (maps/ and bwapi-data/ are copied there by test/CMakeLists.txt).
    #
    #   stardust-test --gtest_filter='Locutus.RunOne'
    #   STARDUST_BUILD_TYPE=Debug stardust-test --gtest_filter='Steamhammer.RunOne'
    stardustTest = pkgs.writeShellApplication {
      name = "stardust-test";
      runtimeInputs = buildTools;
      text = ''
        ${buildSnippet}

        for f in StarDat.mpq BrooDat.mpq Patch_rt.mpq; do
          ln -sf ${scData}/$f "$build/test/$f"
        done

        cd "$build/test"
        exec ./tests "$@"
      '';
    };

    # Play many games in parallel to collect replays.
    #
    #   stardust-batch -n 500 -j 6
    #   stardust-batch -n 100 -f -o ~/replays/vs-steamhammer Steamhammer.RunOne
    #
    # Every game forks into two processes (Stardust and the opponent), and the
    # harness writes logs, learning data and replays relative to its working
    # directory, so each worker gets a directory of its own.
    stardustBatch = pkgs.writeShellApplication {
      name = "stardust-batch";
      runtimeInputs = buildTools ++ [pkgs.coreutils pkgs.findutils pkgs.gzip];
      text = ''
        usage() {
          cat <<EOF
        usage: stardust-batch [-n GAMES] [-j JOBS] [-o OUTDIR] [-t SECONDS] [-f] [TEST ...]

          -n GAMES    total games to play (default 100)
          -j JOBS     games to run at once (default: CPU cores - 1)
          -o OUTDIR   output directory (default: build/batch/<timestamp>)
          -t SECONDS  kill a game that runs longer than this (default 900)
          -f          fresh: clear learning data before every game, so openings
                      are not steered by earlier results in the batch
          TEST        gtest names to rotate through
                      (default: Locutus.RunOne Steamhammer.RunOne Iron.RunOne McRave.RunOne)

        Writes OUTDIR/replays/*.rep, OUTDIR/logs/<game>.log.gz and OUTDIR/games.csv.
        EOF
        }

        games=100
        # A game forks into Stardust and the opponent, but measured CPU is ~1 core
        # per game: Stardust runs flat out while the opponent process uses ~3%.
        jobs=$(( $(nproc) - 1 ))
        out=""
        limit=900
        fresh=0
        while getopts "n:j:o:t:fh" opt; do
          case "$opt" in
            n) games=$OPTARG ;;
            j) jobs=$OPTARG ;;
            o) out=$OPTARG ;;
            t) limit=$OPTARG ;;
            f) fresh=1 ;;
            h) usage; exit 0 ;;
            *) usage >&2; exit 2 ;;
          esac
        done
        shift $((OPTIND - 1))
        tests=("$@")
        [ ''${#tests[@]} -gt 0 ] || tests=(Locutus.RunOne Steamhammer.RunOne Iron.RunOne McRave.RunOne)
        [ "$jobs" -ge 1 ] || jobs=1

        ${buildSnippet}

        out=$(realpath -m "''${out:-$root/build/batch/$(date +%Y%m%d_%H%M%S)}")
        mkdir -p "$out/replays" "$out/logs" "$out/work"
        index="$out/games.csv"
        [ -f "$index" ] || echo "game,worker,test,exit,seconds,replay" > "$index"

        echo "playing $games game(s) with $jobs worker(s): ''${tests[*]}"
        echo "output: $out"

        worker() {
          local w=$1
          local dir="$out/work/w$w"
          mkdir -p "$dir/bwapi-data/read" "$dir/bwapi-data/write" "$dir/replays"
          ln -sfn "$build/test/maps" "$dir/maps"
          # Copied, not linked: bots may write BWTA caches next to their config.
          [ -d "$dir/bwapi-data/AI" ] || cp -r "$build/test/bwapi-data/AI" "$dir/bwapi-data/AI"
          for f in StarDat.mpq BrooDat.mpq Patch_rt.mpq; do
            ln -sf ${scData}/$f "$dir/$f"
          done

          local i
          for ((i = 0; i < games; i++)); do
            (( i % jobs == w )) || continue

            local test=''${tests[i % ''${#tests[@]}]}
            local log
            log="$out/logs/$(printf '%05d' "$i")_''${test%%.*}.log"

            if [ "$fresh" = 1 ]; then
              rm -rf "$dir/bwapi-data/read" "$dir/bwapi-data/write"
              mkdir -p "$dir/bwapi-data/read" "$dir/bwapi-data/write"
            fi

            local start=$SECONDS rc=0
            (cd "$dir" && timeout --kill-after=10 "$limit" "$build/test/tests" --gtest_filter="$test") > "$log" 2>&1 || rc=$?
            gzip -f "$log"

            local replay=""
            local r
            while IFS= read -r -d "" r; do
              replay=$(basename "$r")
              mv -n "$r" "$out/replays/"
            done < <(find "$dir/replays" -maxdepth 1 -name '*.rep' -print0)
            # Release builds log to the console, so these are empty.
            find "$dir/replays" -mindepth 1 -maxdepth 1 -name '*.rep.log' -exec rm -rf {} +

            printf '%d,%d,%s,%d,%d,"%s"\n' "$i" "$w" "$test" "$rc" "$((SECONDS - start))" "$replay" >> "$index"
            echo "[$(( $(wc -l < "$index") - 1 ))/$games] game $i $test exit=$rc $((SECONDS - start))s ''${replay:-no replay}"
          done
        }

        trap 'echo "stopping"; kill 0' INT TERM
        for ((w = 0; w < jobs; w++)); do
          worker "$w" &
        done
        wait

        echo "done: $(find "$out/replays" -name '*.rep' | wc -l) replay(s) in $out/replays"
      '';
    };
  in {
    packages.${system} = {
      default = stardustTest;
      stardust-test = stardustTest;
      stardust-batch = stardustBatch;
      sc-data = scData;
    };

    apps.${system} = {
      default = {
        type = "app";
        program = pkgs.lib.getExe stardustTest;
      };
      batch = {
        type = "app";
        program = pkgs.lib.getExe stardustBatch;
      };
    };

    devShells.${system}.default = (pkgs.mkShell.override {stdenv = llvm.libcxxStdenv;}) {
      packages = buildTools ++ [stardustTest stardustBatch pkgs.gdb];
      hardeningDisable = ["all"];
      CCACHE_COMPILERCHECK = "content";
      STARDUST_SC_DATA = scData;
    };
  };
}
