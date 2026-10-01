# Changelog

## [1.0.0](https://github.com/thedavidweng/sukiru/compare/v1.0.0...v1.0.0) (2026-10-01)


### ✨ Features

* add SwiftUI app shell via XcodeGen (Sukiru.app) ([a1c7ed2](https://github.com/thedavidweng/sukiru/commit/a1c7ed2baf680fc6d8ceacb5d5324ad2ccdf5846))
* **cli:** add scan and capabilities commands with environment overrides ([a3394c1](https://github.com/thedavidweng/sukiru/commit/a3394c18744231f049372ecc33a52017c2c8b7f1))
* **cli:** wire the scan engine to real capabilities with user-scope dedup ([bbb266d](https://github.com/thedavidweng/sukiru/commit/bbb266de95a572e5b8de78d24da70cceaebcfbc6))
* detect installer capabilities with unavailable reasons and caching ([08c95d8](https://github.com/thedavidweng/sukiru/commit/08c95d81ab42becd6d89a804a65f774451057562))
* find Node.js installed through version managers ([240fab7](https://github.com/thedavidweng/sukiru/commit/240fab70923600e71f10d5c2558228a7e30ac5a5))
* **health:** add detection rules with severities and evidence ([55bedd5](https://github.com/thedavidweng/sukiru/commit/55bedd51e1bbcfc9565885900bb8320e70f87ae0))
* **health:** explain the blast radius of dangerous removals ([be496f9](https://github.com/thedavidweng/sukiru/commit/be496f9e98ca4be9d2ea026daa1080d4fb408bb0))
* never download or update the skills CLI without asking ([bb1d6c4](https://github.com/thedavidweng/sukiru/commit/bb1d6c4c64e490b2f1538800945b79031afd2631))
* problem-first health with one-click fixes ([4e4c695](https://github.com/thedavidweng/sukiru/commit/4e4c6958305622003127b5127f10fa78b8d88f36))
* redesign the app icon around the katakana ス ([92e79b3](https://github.com/thedavidweng/sukiru/commit/92e79b3749fb59ccc7e32d8ac50a211666afab5e))
* release packaging, CI, and Homebrew distribution ([e9b8568](https://github.com/thedavidweng/sukiru/commit/e9b8568500bc7186de10001b53af6dee05149ccc))
* **repair:** add post-run diff and one-click rollback ([dadf511](https://github.com/thedavidweng/sukiru/commit/dadf511a5eaabeb94d4049c6451859e365645606))
* **repair:** add snapshot capture, restore, and retention ([ae155b1](https://github.com/thedavidweng/sukiru/commit/ae155b105c99f94f40a8fe2df22e876b83949d38))
* **repair:** build command batches from user decisions ([ce4e6c4](https://github.com/thedavidweng/sukiru/commit/ce4e6c4471cbae126494ce643c6fd81a0d91a78a))
* **repair:** execute batches serially through the official CLIs ([b1ce3d0](https://github.com/thedavidweng/sukiru/commit/b1ce3d045a82d4f15fc40dd5b6bf703bfac318b4))
* **scan:** add the 56-host table, host detection, and workspace enumeration ([ced73ca](https://github.com/thedavidweng/sukiru/commit/ced73ca25b00091a60f2daf1dd876fbb74c6eb5b))
* **scan:** discover placements, symlinks, and broken links ([72d9a75](https://github.com/thedavidweng/sukiru/commit/72d9a751afe4c52042688a2503520cafaabebbaa))
* **scan:** hash skill content with byte-exact computedHash parity ([571dea3](https://github.com/thedavidweng/sukiru/commit/571dea3e0c1b19c45f1363fd81fb2530ba843b65))
* **scan:** never mark hash-explained placements as ambiguous ([6dd5210](https://github.com/thedavidweng/sukiru/commit/6dd5210fe986d41ba218a580ea40e625f6ae32bc))
* **scan:** parse frontmatter, GitHub provenance, and Vercel lockfiles ([4d351f9](https://github.com/thedavidweng/sukiru/commit/4d351f9542ada267539bc84a5e067b19e3a87f5c))
* **scan:** resolve four-state ownership and surface provenance ([ecf0f6c](https://github.com/thedavidweng/sukiru/commit/ecf0f6cec1f8d6dbf11c68663845f35ed0287c7b))
* search, preview, and install skills in the app ([e01a4a2](https://github.com/thedavidweng/sukiru/commit/e01a4a284b2ac7e248b590a2eabdb091b792364d))
* standard Settings scene and window toolbar ([7c0ee0b](https://github.com/thedavidweng/sukiru/commit/7c0ee0bd468a1c2515352a2475244c7679779e9a))
* **ui:** add app navigation and the health fixture corpus ([ec1051a](https://github.com/thedavidweng/sukiru/commit/ec1051a6b0232ba71996b2ceda9d5e3478da220b))
* **ui:** add Health with grouped findings, evidence, and workspace filter ([36b576e](https://github.com/thedavidweng/sukiru/commit/36b576e162e28f53694be9b6e3b511380cac883d))
* **ui:** add Library with host presence, provenance, and finding links ([5a5152c](https://github.com/thedavidweng/sukiru/commit/5a5152cc94c1783affffcecf85936e46c2fed58f))
* **ui:** add Pending Changes and Snapshots ([6dcfecd](https://github.com/thedavidweng/sukiru/commit/6dcfecdb27ae3b7b5c32b2e92f08bb9874bf71bb))
* **ui:** add Quick Look, Refresh, and the installer capability panel ([c581fb1](https://github.com/thedavidweng/sukiru/commit/c581fb137b1f94f135a287092f537dbf7605e7dc))
* **ui:** adopt first-party library layout and functional settings ([bb09136](https://github.com/thedavidweng/sukiru/commit/bb09136c425766623f2322b8e840af9ea5f3a126))
* **ui:** complete English and Chinese localization and keyboard access ([4b9cc71](https://github.com/thedavidweng/sukiru/commit/4b9cc71727e6c657c3e4c138d7f81ed1e38597d9))
* **ui:** implement native Focus library ([ebe231f](https://github.com/thedavidweng/sukiru/commit/ebe231fc622b8e15a151a200af3429cdc4f13dda))
* **ui:** refine native library and detail views ([c96bc96](https://github.com/thedavidweng/sukiru/commit/c96bc96e6a9417b13054fb0a09cb060321311038))


### 🐛 Bug Fixes

* make the app icon visible on light backgrounds ([930afd3](https://github.com/thedavidweng/sukiru/commit/930afd37a610de98eebdfa1f887d11d79c52bbcd))
* rollback preserves pre-existing empty container dirs ([d91234d](https://github.com/thedavidweng/sukiru/commit/d91234d898e14a9212897f569d851eb6e45c0409))
* **scan:** address review findings and a copy-mode false positive ([c5c01bb](https://github.com/thedavidweng/sukiru/commit/c5c01bb7d4e505a14f97df21216cc6a33cdf3c1d))
* **scan:** preserve unknown lock fields in scan output ([0921781](https://github.com/thedavidweng/sukiru/commit/0921781014b6a201d28a1e4920d4b2e7997a17a7))
* **test:** keep the adoption fixture home directory in git ([abea75a](https://github.com/thedavidweng/sukiru/commit/abea75a009943e41afc8d309c0c8819ccb1cc17a))
* **test:** match real rustc Debug quoting in symlink fixture digests ([a0ba6fa](https://github.com/thedavidweng/sukiru/commit/a0ba6fafdee8c8e40405ae04409c59dfe1c03cdb))
* **tests:** persist empty fixture dirs with .gitkeep ([#8](https://github.com/thedavidweng/sukiru/issues/8)) ([0637256](https://github.com/thedavidweng/sukiru/commit/063725682f04c0892111d4a6688d8e04172d7560))
* **ui:** add a View menu command to reveal findings in Library ([7db51bc](https://github.com/thedavidweng/sukiru/commit/7db51bc14f1e3f86ad778f050f849207e6a9d6a4))
* **ui:** refine native library and agent identity ([57ae21b](https://github.com/thedavidweng/sukiru/commit/57ae21b38281916f1cf814c16a77a5934efce8a9))


### ⚡ Performance

* **app:** derive Health state once per change, not per render ([dc75aa0](https://github.com/thedavidweng/sukiru/commit/dc75aa0d780f06eb2dc67298b04dfc0e4ebfad8d))
* **scan:** read each skill directory once and probe CLIs concurrently ([0470b9f](https://github.com/thedavidweng/sukiru/commit/0470b9f422d945465baff561453755602676046e))


### ♻️ Refactoring

* clean Swift code and app footprint ([8981889](https://github.com/thedavidweng/sukiru/commit/898188939e363c094355074ec0d921b293e851e3))
* replace internal planning references with plain explanations ([e891dd5](https://github.com/thedavidweng/sukiru/commit/e891dd57fb9013e59e92ad791deac2e6f7c3da9f))
* **ui:** attach commands to main window scene ([e4ea033](https://github.com/thedavidweng/sukiru/commit/e4ea0336856c5b6644c135c5fca9fd375f87dce9))


### 📝 Documentation

* add ADR-0006 on the pure-Swift native red line ([e4da727](https://github.com/thedavidweng/sukiru/commit/e4da72797bb8ebd18a6825091dbaa3a4634f08c7))
* add website, Chinese README, and privacy policy ([cae53af](https://github.com/thedavidweng/sukiru/commit/cae53af08354f7e352671b095cc0359b833baa58))
* README reflects shipped scan, health UI, and repair ([f9d3a01](https://github.com/thedavidweng/sukiru/commit/f9d3a01dd2ce9506a68a86a9bcaf4da1fcb2740d))
* record the pivot to Sukiru with ADRs, glossary, and collision matrix ([e1209e0](https://github.com/thedavidweng/sukiru/commit/e1209e09fa0b8688c4e23fc8b818d89f4e9ae835))
* remove archived Rust product plans from main ([51ff8c1](https://github.com/thedavidweng/sukiru/commit/51ff8c1f352c6337a04c0033079488a01d5f2ac5))
* translate documentation to English and add community files ([4eb9082](https://github.com/thedavidweng/sukiru/commit/4eb9082baecd07436dc5dcb04cc6623634c9aa4f))


### 🔧 Chores

* release 1.0.0 from the Swift rewrite ([4dc5735](https://github.com/thedavidweng/sukiru/commit/4dc5735d35e1ceb66e20a2fbaeddaf5cf3fe8d44))
