# VecOK

Utility tweak build pipeline (Theos + GitHub Actions).

## Layout

```
Makefile                      Theos project
tw/Tweak.m                    tweak source (all target identifiers come from build-time defines)
ci/gen.py                     injects build secrets -> generated/ok_conf.h + dsc/*.plist + dsc/control.*
ci/setup_theos.sh             installs the matching Theos for each scheme
ci/build.sh                   builds + assembles payload + packs the deb
.github/workflows/build.yml   two runners (rootless / roothide) + release
```

## How secrets are used

Nothing target-specific is committed. `generated/` and `dsc/` artifacts are
produced at build time from repository secrets and are listed in `.gitignore`.

## Build locally

```
export OK_TARGET_CLASS=... OK_PRO_KEY=... OK_BUNDLES=... etc
python3 ci/gen.py
bash ci/setup_theos.sh rootless
bash ci/build.sh rootless
```

## Notes

- `-Wl,-no_fixup_chains` is required so the constructor lands in
  `__DATA_CONST,__mod_init_func` (a pointer array the loaders understand)
  rather than `__TEXT,__init_offsets` (32-bit relative offsets).
- The tweak's constructor only marks startup; all real work is dispatched to
  the main queue so nothing heavy runs during dyld construction.
- Every replaced implementation can chain back to the original; a miss is
  always passed through to the original rather than returning an empty value.
- Packages are compressed with gzip for broad dpkg compatibility.
