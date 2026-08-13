# PyPI top-10k native-dependency survey: detailed findings

Survey date: **2026-07-16**, ranking by 30-day downloads
([hugovk/top-pypi-packages](https://hugovk.github.io/top-pypi-packages/),
snapshot 2026-07-01, ClickHouse source). See README.md for methodology and
reproduction steps.

## 1. Pure Python vs native (the package itself)

| cutoff     | pure  | native | % native | native w/ pure fallback wheel |
| ---------- | ----- | ------ | -------- | ----------------------------- |
| top 100    | 75    | 25     | 25.0%    | 9                             |
| top 1,000  | 792   | 208    | 20.8%    | 28                            |
| top 10,000 | 8,538 | 1,460  | 14.6%    | 73                            |

“Native” = the latest release publishes at least one platform-specific wheel, or
its sdist builds compiled code (`ext_modules`, Cython, Cargo, CMake/meson, …).
Two placeholder packages (`aaaaaaaaa`, `timedelta`) are 404/fileless and
excluded from top-10k percentages. `pyspark` counts as pure: its 450 MB payload
is JVM jars, not compiled CPython extensions.

## 2. Transitive: does the runtime dependency closure contain native code?

Markers evaluated for CPython 3.12 / linux / x86_64, default extras only.

| cutoff     | pure closure | pure pkg, native deps | native itself | needs native anywhere |
| ---------- | ------------ | --------------------- | ------------- | --------------------- |
| top 100    | 60           | 15                    | 25            | 40 (40.0%)            |
| top 1,000  | 465          | 327                   | 208           | 535 (53.5%)           |
| top 10,000 | 4,147        | 4,390                 | 1,460         | 5,850 (58.5%)         |

Most common _direct_ native dependencies among pure packages that pull native
code:

| top 1,000    | count | top 10,000   | count |
| ------------ | ----- | ------------ | ----- |
| protobuf     | 63    | numpy        | 647   |
| grpcio       | 50    | pyyaml       | 481   |
| pyyaml       | 29    | pandas       | 297   |
| cryptography | 21    | protobuf     | 253   |
| numpy        | 20    | aiohttp      | 228   |
| aiohttp      | 14    | cryptography | 225   |
| wrapt        | 13    | scipy        | 220   |
| pandas       | 12    | pillow       | 178   |
| pyarrow      | 10    | grpcio       | 154   |
| sqlalchemy   | 9     | torch        | 146   |
| websockets   | 8     | psutil       | 135   |
| pillow       | 8     | lxml         | 120   |
| psutil       | 6     | sqlalchemy   | 116   |
| tornado      | 6     | matplotlib   | 97    |
| markupsafe   | 5     | scikit-learn | 96    |

## 3. Native packages: what they're built from

### Top 100: 25 native packages

| build backend | n   |     | abi kind    | n   |     | primary language | n   |
| ------------- | --- | --- | ----------- | --- | --- | ---------------- | --- |
| setuptools    | 16  |     | cp-specific | 23  |     | cython           | 11  |
| maturin       | 4   |     | abi3        | 2   |     | c                | 8   |
| meson         | 3   |     |             |     |     | rust             | 4   |
| bazel         | 1   |     |             |     |     | binary/unknown   | 1   |
| scikit-build  | 1   |     |             |     |     | c++              | 1   |

cffi runtime users: 1. Most-bundled shared libraries (auditwheel-vendored in
manylinux wheels):

| lib           | pkgs | lib           | pkgs | lib         | pkgs |
| ------------- | ---- | ------------- | ---- | ----------- | ---- |
| gfortran-rt   | 2    | openblas/blas | 2    | libwebp     | 1    |
| brotli        | 1    | zstd          | 1    | libsharpyuv | 1    |
| libopenjp2    | 1    | freetype      | 1    | libpng      | 1    |
| gui/x11-stack | 1    | libtiff       | 1    | libjpeg     | 1    |
| liblcms2      | 1    | harfbuzz      | 1    | libavif     | 1    |
| xz            | 1    | arrow         | 1    |             |      |

### Top 1,000: 208 native packages

| build backend | n   |     | abi kind        | n   |     | primary language | n   |
| ------------- | --- | --- | --------------- | --- | --- | ---------------- | --- |
| setuptools    | 153 |     | cp-specific     | 130 |     | c                | 67  |
| maturin       | 30  |     | none (no C API) | 42  |     | binary/unknown   | 45  |
| scikit-build  | 10  |     | abi3            | 35  |     | cython           | 42  |
| meson         | 7   |     | pypy39_pp73     | 1   |     | rust             | 36  |
| hatchling     | 5   |     |                 |     |     | c++              | 18  |
| pipcl         | 2   |     |                 |     |     |                  |     |
| bazel         | 1   |     |                 |     |     |                  |     |

cffi runtime users: 8. Most-bundled shared libraries (auditwheel-vendored in
manylinux wheels):

| lib         | pkgs | lib              | pkgs | lib           | pkgs |
| ----------- | ---- | ---------------- | ---- | ------------- | ---- |
| cuda        | 26   | openssl          | 8    | kerberos      | 5    |
| gfortran-rt | 4    | libpng           | 4    | libselinux    | 4    |
| libwebp     | 3    | libsharpyuv      | 3    | gui/x11-stack | 3    |
| libavif     | 3    | libpq (postgres) | 3    | cyrus-sasl    | 3    |
| openmp-rt   | 3    | ffmpeg           | 3    | libvpx        | 3    |
| libdrm      | 3    | openblas/blas    | 2    | zstd          | 2    |
| libtiff     | 2    | libjpeg          | 2    | xz            | 2    |
| liblber     | 2    | libldap          | 2    | libpcre       | 2    |

### Top 10,000: 1460 native packages

| build backend                      | n   |     | abi kind        | n   |     | primary language | n   |
| ---------------------------------- | --- | --- | --------------- | --- | --- | ---------------- | --- |
| setuptools                         | 958 |     | cp-specific     | 909 |     | binary/unknown   | 428 |
| maturin                            | 225 |     | abi3            | 259 |     | c                | 381 |
| scikit-build                       | 108 |     | none (no C API) | 233 |     | rust             | 245 |
| unknown                            | 58  |     | unknown         | 57  |     | cython           | 227 |
| hatchling                          | 28  |     | pypy39_pp73     | 1   |     | c++              | 179 |
| meson                              | 20  |     | cp27mu          | 1   |     |                  |     |
| poetry                             | 16  |     |                 |     |     |                  |     |
| cmeel                              | 15  |     |                 |     |     |                  |     |
| pipcl                              | 4   |     |                 |     |     |                  |     |
| pyqtbuild                          | 4   |     |                 |     |     |                  |     |
| pyqt-qt-wheel                      | 4   |     |                 |     |     |                  |     |
| pdm                                | 4   |     |                 |     |     |                  |     |
| distlib                            | 2   |     |                 |     |     |                  |     |
| uv                                 | 2   |     |                 |     |     |                  |     |
| bazel                              | 1   |     |                 |     |     |                  |     |
| sqlite-dist                        | 1   |     |                 |     |     |                  |     |
| scripts/build/binary_only_wheel.py | 1   |     |                 |     |     |                  |     |
| austin-dist                        | 1   |     |                 |     |     |                  |     |
| ziglang                            | 1   |     |                 |     |     |                  |     |
| flit                               | 1   |     |                 |     |     |                  |     |
| go-to-wheel                        | 1   |     |                 |     |     |                  |     |
| gmsh_wheel                         | 1   |     |                 |     |     |                  |     |
| dbt-ci                             | 1   |     |                 |     |     |                  |     |
| act                                | 1   |     |                 |     |     |                  |     |
| nuitka                             | 1   |     |                 |     |     |                  |     |
| makepanda                          | 1   |     |                 |     |     |                  |     |

cffi runtime users: 42. Most-bundled shared libraries (auditwheel-vendored in
manylinux wheels):

| lib           | pkgs | lib        | pkgs | lib        | pkgs |
| ------------- | ---- | ---------- | ---- | ---------- | ---- |
| openmp-rt     | 50   | cuda       | 44   | openssl    | 40   |
| gfortran-rt   | 23   | libpng     | 23   | xz         | 22   |
| kerberos      | 21   | libselinux | 21   | zstd       | 17   |
| gui/x11-stack | 17   | bzip2      | 17   | curl-stack | 14   |
| libjpeg       | 13   | libpcre2-8 | 13   | libpcre    | 12   |
| ffmpeg        | 12   | libwebp    | 11   | brotli     | 11   |
| qt            | 11   | libtbb     | 11   | libtiff    | 10   |
| libcrypt      | 10   | cyrus-sasl | 10   | libgmp     | 10   |

## 4. The 25 native packages in the top 100

| rank | package            | build                    | language       | pure fallback wheel |
| ---- | ------------------ | ------------------------ | -------------- | ------------------- |
| 8    | charset-normalizer | setuptools               | c              | yes                 |
| 11   | cryptography       | maturin                  | rust           |                     |
| 17   | pyyaml             | setuptools               | cython         |                     |
| 18   | numpy              | meson                    | cython         |                     |
| 19   | cffi               | setuptools               | c              |                     |
| 26   | pydantic-core      | maturin                  | rust           |                     |
| 30   | protobuf           | bazel-wheelmaker 1.0     | c              | yes                 |
| 34   | pandas             | meson                    | cython         |                     |
| 36   | markupsafe         | setuptools               | c              |                     |
| 47   | litellm            | maturin                  | rust           |                     |
| 48   | aiohttp            | setuptools               | cython         |                     |
| 52   | yarl               | setuptools               | cython         | yes                 |
| 54   | propcache          | setuptools               | cython         | yes                 |
| 55   | rpds-py            | maturin                  | rust           |                     |
| 56   | multidict          | setuptools               | c              | yes                 |
| 65   | frozenlist         | setuptools               | cython         | yes                 |
| 72   | sglang             | setuptools               | binary/unknown |                     |
| 79   | pillow             | setuptools               | c              |                     |
| 83   | wrapt              | setuptools               | c              | yes                 |
| 85   | greenlet           | setuptools               | c++            |                     |
| 86   | grpcio             | setuptools               | cython         |                     |
| 91   | websockets         | setuptools               | c              | yes                 |
| 93   | scipy              | meson                    | cython         |                     |
| 95   | pyarrow            | scikit-build-core 0.12.2 | cython         |                     |
| 99   | sqlalchemy         | setuptools               | cython         | yes                 |

## 5. Native reach: how much each native package is pulled

For every top-10k package, its runtime closure was computed; a native package's
_reach_ is how many top-10k packages contain it. Download-weighting sums the
dependents' 30-day downloads.

| native package         | own rank | pulled by (pkgs) | dl-weighted (30d) | own downloads (30d) | language       |
| ---------------------- | -------- | ---------------- | ----------------- | ------------------- | -------------- |
| charset-normalizer     | 8        | 2,164            | 21.04 B           | 1,481 M             | c              |
| numpy                  | 18       | 1,358            | 6.95 B            | 1,090 M             | cython         |
| pyyaml                 | 17       | 1,290            | 8.14 B            | 1,108 M             | cython         |
| pydantic-core          | 26       | 1,162            | 10.28 B           | 938 M               | rust           |
| cffi                   | 19       | 1,070            | 15.28 B           | 1,084 M             | c              |
| markupsafe             | 36       | 1,053            | 6.54 B            | 745 M               | c              |
| cryptography           | 11       | 886              | 12.74 B           | 1,347 M             | rust           |
| protobuf               | 30       | 808              | 13.11 B           | 857 M               | c              |
| wrapt                  | 83       | 545              | 5.77 B            | 464 M               | c              |
| multidict              | 56       | 520              | 7.02 B            | 575 M               | c              |
| rpds-py                | 55       | 510              | 5.83 B            | 577 M               | rust           |
| propcache              | 54       | 506              | 6.93 B            | 582 M               | cython         |
| yarl                   | 52       | 504              | 6.32 B            | 608 M               | cython         |
| pillow                 | 79       | 477              | 2.41 B            | 494 M               | c              |
| psutil                 | 107      | 472              | 2.21 B            | 383 M               | c              |
| grpcio                 | 86       | 467              | 7.87 B            | 443 M               | cython         |
| pandas                 | 34       | 463              | 1.91 B            | 770 M               | cython         |
| frozenlist             | 65       | 459              | 6.66 B            | 540 M               | cython         |
| aiohttp                | 48       | 457              | 5.51 B            | 632 M               | cython         |
| scipy                  | 93       | 417              | 1.50 B            | 427 M               | cython         |
| greenlet               | 85       | 373              | 2.38 B            | 447 M               | c++            |
| sqlalchemy             | 99       | 333              | 1.73 B            | 408 M               | cython         |
| regex                  | 102      | 311              | 2.72 B            | 400 M               | c              |
| websockets             | 91       | 256              | 2.26 B            | 430 M               | c              |
| orjson                 | 195      | 233              | 2.14 B            | 204 M               | rust           |
| cuda-bindings          | 565      | 208              | 0.99 B            | 50 M                | binary/unknown |
| nvidia-cuda-nvrtc      | 668      | 198              | 1.08 B            | 39 M                | binary/unknown |
| lxml                   | 108      | 197              | 1.38 B            | 375 M               | cython         |
| nvidia-cublas          | 657      | 197              | 1.04 B            | 40 M                | binary/unknown |
| nvidia-cuda-cccl       | 3722     | 197              | 1.00 B            | 2 M                 | binary/unknown |
| nvidia-nvshmem-cu13    | 679      | 196              | 0.97 B            | 38 M                | binary/unknown |
| nvidia-cudnn-cu13      | 659      | 195              | 0.97 B            | 40 M                | binary/unknown |
| nvidia-cusparselt-cu13 | 663      | 195              | 0.97 B            | 40 M                | binary/unknown |
| nvidia-nccl-cu13       | 661      | 195              | 0.97 B            | 40 M                | binary/unknown |
| triton                 | 454      | 195              | 0.97 B            | 70 M                | binary/unknown |
| torch                  | 359      | 194              | 0.87 B            | 92 M                | binary/unknown |
| hf-xet                 | 161      | 177              | 2.54 B            | 248 M               | rust           |
| pyarrow                | 95       | 177              | 1.30 B            | 418 M               | cython         |
| fonttools              | 156      | 171              | 0.57 B            | 251 M               | c              |
| contourpy              | 179      | 164              | 0.53 B            | 218 M               | c++            |
| pyobjc-core            | 2578     | 161              | 0.10 B            | 3 M                 | c              |
| pyobjc-framework-cocoa | 2627     | 160              | 0.10 B            | 3 M                 | c              |
| kiwisolver             | 172      | 158              | 0.52 B            | 225 M               | c++            |
| matplotlib             | 159      | 156              | 0.27 B            | 249 M               | c++            |
| scikit-learn           | 177      | 152              | 0.29 B            | 220 M               | cython         |
| msgpack                | 147      | 147              | 0.67 B            | 280 M               | cython         |
| jiter                  | 115      | 146              | 2.31 B            | 350 M               | rust           |
| zstandard              | 235      | 140              | 1.92 B            | 172 M               | c              |
| pendulum               | 437      | 139              | 0.51 B            | 75 M                | rust           |
| msgspec                | 625      | 134              | 0.99 B            | 44 M                | c              |

The interactive flame chart (`flame.html`) shows the same data subdivided by
_route_: under each native package, the direct dependents through which the
pulls flow.
