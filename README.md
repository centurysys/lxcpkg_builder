# lxcpkg

`lxcpkg` は、MA Series WebUI の LXC 管理機能で使用する `.lxcpkg` パッケージを作成するための補助ツールです。

準備済みの root filesystem directory を入力として、以下をまとめて実行します。

- rootfs の architecture 自動判定
- `mksquashfs` による `rootfs.sqfs` 作成
- cache / tmp / boot など不要領域の除外
- `rootfs.sqfs` の SHA256 計算
- `manifest.json` 作成
- `manifest.json` と `rootfs.sqfs` を含む `.lxcpkg` archive 作成
- data mount の owner / group / mode 設定
- rootfs 内の `/etc/passwd` / `/etc/group` を使った user / group 名の解決
- base `.lxcpkg` と WebUI から取得した `.lxcdev` を組み合わせた rebuild
- Linux Containers Image Server から取得した rootfs の `.lxcpkg` 化
- rootfs tarball からの `.lxcpkg` 化
- `lxc-create -t download` で作成済みの LXC directory からの `.lxcpkg` 化
- 既存 `.lxcpkg` の `packageId` / `name` / `version` metadata rewrite

このツールは汎用 LXC パッケージャではありません。
弊社機器の WebUI / AppServer の `.lxcpkg` 仕様に合わせた専用ツールです。

## このツールでできること

`lxcpkg` は、弊社機器の仮想インスタンス機能で使う `.lxcpkg` を作るためのツールです。

Docker の `pull` のように「外部のイメージを取得してすぐ使い始める」導線は便利ですが、組み込み機器ではそのまま Docker daemon を常駐させる運用が重すぎる場合があります。`lxcpkg` は、Linux Containers / Incus Image Server 由来の rootfs や、手元の rootfs directory / tarball を、弊社機器向けの `.lxcpkg` に変換します。

生成される `.lxcpkg` は、以下の方針で運用しやすい形になります。

- rootfs は squashfs として read-only 配布
- 書き込み差分は overlay として分離
- IP アドレス、DNS、device injection はホスト側で管理
- `/dev/video*`, `/dev/hailo0`, GPIO, serial device などをホスト側から注入しやすい
- rootfs の cache / log / tmp 掃除は bubblewrap sandbox 内で実行
- Debian / Ubuntu 系では `apt.conf.d` / `dpkg.cfg.d` に容量爆増防止設定を入れられる
- Debian / Ubuntu 系の OpenSSH server では、missing host key 生成用 systemd drop-in を自動追加できる

つまり、汎用コンテナ環境をそのまま持ち込むのではなく、弊社機器上で安全に扱いやすい LXC パッケージへ変換するための入口です。

主な作成経路は次の 3 つです。

```text
展開済み rootfs directory
  -> lxcpkg build

Linux Containers / Incus Image Server
  -> lxcpkg build-download

rootfs tarball
  -> lxcpkg build-tarball
```

既存 `.lxcpkg` を新しい package lineage の起点として使いたい場合は、rootfs を再生成せずに metadata だけを書き換える `rewrite-metadata` を使えます。

```text
既存 .lxcpkg
  -> lxcpkg rewrite-metadata
```

`.lxcpkg` を作成する各 command では、出力先を `--output` または `-o` で明示してください。
`--output` が無い場合は、download / extract / squashfs 作成などの重い処理を開始する前にエラー終了します。

よく使う option には short option も用意しています。手順書では意味が分かりやすい long option、日常作業では short option、という使い分けができます。

```text
-o, --output       出力する .lxcpkg / .lxcdelta file
-P, --package-id   package ID
-n, --name         package name
-V, --version      package version
-a, --arch         target architecture
-r, --rootfs       build で使う rootfs directory
-d, --dist         build-download で取得する distribution
-R, --release      build-download で取得する release
-b, --bits         ARM bit width。64 は arm64、32 は armhf
-p, --preset       appliance preset
-t, --tarball      build-tarball で使う rootfs tarball
-L, --lxc-dir      pack-lxc-dir で使う LXC directory
-v, --verbose      詳細ログ
```

---

## 想定する `.lxcpkg` の中身

生成される `.lxcpkg` は zip archive です。中身は次の 2 ファイルです。

```text
manifest.json
rootfs.sqfs
```

例:

```sh
unzip -l Debian.lxcpkg
```

```text
Archive:  Debian.lxcpkg
  Length      Date    Time    Name
---------  ---------- -----   ----
      420  2026-05-30 16:20   manifest.json
 39448576  2026-05-30 16:20   rootfs.sqfs
---------                     -------
 39448996                     2 files
```

---

## 必要な外部コマンド

`lxcpkg build` は以下の外部コマンドを使用します。

- `mksquashfs`
- `zip`

`lxcpkg build-download` / `lxcpkg build-tarball` / `lxcpkg pack-lxc-dir` は、追加で以下の外部コマンドを使用します。

- `lxc-create`
- `lxc-download` template
- `tar`
- `bubblewrap` (`bwrap`)
- `find`

`lxcpkg rebuild` は追加で以下の外部コマンドを使用します。

- `unzip`
- `tar`
- `zstd`
- `mount`
- `umount`

`lxcpkg rewrite-metadata` は追加で以下の外部コマンドを使用します。

- `unzip`
- `zip`

Debian / Ubuntu 系では、概ね以下で入ります。

```sh
sudo apt install squashfs-tools zip unzip tar zstd mount lxc lxc-templates bubblewrap
```

`build-download` は `lxc-create -t download` を使って Linux Containers Image Server から rootfs を取得します。
`--normalize` / `--minimize` / `--network-mode host-configured` による rootfs 変更は `bwrap` 内で実行します。ホスト側 `/` は read-only、対象 rootfs だけを read-write で bind mount するため、掃除処理が誤ってホスト rootfs を破壊するリスクを抑えます。
`rebuild` は squashfs の loop mount と overlayfs mount を行うため、Linux 上で root 権限が必要です。
`rewrite-metadata` は `.lxcpkg` の zip 展開と再作成だけを行うため、root 権限や mount は不要です。


### Rootfs cleanup safety

`build-download` / `build-tarball` / `pack-lxc-dir` の normalize / minimize 処理は、rootfs の中身を実際に変更します。
そのため、`lxcpkg` は cache / log / tmp などを掃除するときに、ホストの mount namespace 上で直接 `rm -rf` 相当の操作を行いません。

破壊的な処理は `bubblewrap` sandbox 内で実行します。

```text
host /      -> sandbox /      read-only
target rootfs -> sandbox /mnt  read-write
```

この構成により、仮に rootfs 内に予期しない symlink があっても、ホスト側 rootfs は read-only として見えるため、掃除処理がホスト側の `/etc`, `/var`, `/usr` などを削除する事故を避けやすくなります。

`bwrap` が無い環境では、normalize / minimize / host-configured network profile は失敗します。
これは意図した挙動です。安全性を落としてホスト namespace で直接掃除する fallback は用意していません。

---


### OpenSSH host key regeneration

`lxcpkg` は、Debian / Ubuntu 系の systemd rootfs に OpenSSH server が入っている場合、missing host key を初回起動時に生成できるように `ssh.service` drop-in を標準で追加します。

対象になる条件は以下です。

```text
/usr/sbin/sshd などの sshd binary が存在する
/usr/bin/ssh-keygen などの ssh-keygen binary が存在する
/lib/systemd/system/ssh.service または同等の systemd unit が存在する
```

追加される drop-in は以下です。

```text
/etc/systemd/system/ssh.service.d/10-ensure-host-keys.conf
```

内容は、`sshd -t` より前に `ssh-keygen -A` を実行するものです。これにより、release cleanup / scrub によって `/etc/ssh/ssh_host_*` を削除した rootfs でも、初回起動時に host key を生成してから sshd を起動できます。

Alpine / OpenRC の `sshd` init script は標準で missing host key を生成するため、systemd drop-in は追加されません。

この補正を明示的に無効化したい場合は、`build`, `build-download`, `build-tarball`, `pack-lxc-dir`, `rebuild` で `--no-ensure-ssh-host-keys` を指定します。

---


## 製品向け preset

`build`, `build-download`, `build-tarball`, `pack-lxc-dir` では、製品向け rootfs 調整をまとめて指定する `--preset` を使えます。

```text
--preset alpine-appliance
  normalize=product
  minimize=alpine
  network-mode=host-configured

--preset debian-appliance
  normalize=product
  minimize=debian
  network-mode=host-configured

--preset ubuntu-appliance
  normalize=product
  minimize=debian
  network-mode=host-configured

--preset auto-appliance
  normalize=product
  minimize=auto
  network-mode=host-configured
```

Debian / Ubuntu 系の `minimize=debian` では、rootfs 内に以下のような設定を入れます。

- `APT::Install-Recommends "false";`
- `APT::Install-Suggests "false";`
- `Acquire::Languages "none";`
- `/usr/share/doc` は copyright 以外を除外
- man / info / lintian / locale などを dpkg の install 対象から除外

これにより、コンテナ内でユーザーが `apt install` したときに、推奨パッケージや多言語ファイル、man page などが大量に入り、意図せず巨大な rootfs / overlay を作ってしまう事故を避けやすくなります。

`--preset` は製品向けの既定値セットです。個別に調整したい場合は `--preset none` のまま、`--normalize`, `--minimize`, `--network-mode` を直接指定してください。

---

## Nimble dependencies

このプロジェクトでは以下を使用します。

```nim
requires "argparse >= 4.0.2"
requires "results"
requires "checksums"
```

---

## 基本的な使い方

### 対話形式で作成する

不足している option は対話入力で補完されます。

```sh
./lxcpkg build --rootfs trixie64
```

入力例:

```text
Package name: Debian
Package ID [com.example.Debian]:
Package version [1.0.0]:
Output .lxcpkg file [Debian.lxcpkg]:
Rootfs mode:
  1) persistent  - storage-backed rootfs overlay
  2) volatile    - tmpfs rootfs overlay, discarded on stop
  3) snapshot    - tmpfs rootfs overlay with save/restore support
Select rootfs mode [2]: 1
Add data mount? [y/N]: y
Data mount name: Debian
Target path in container: /var/hoge
Owner user or uid [root]: user1
Group or gid [user1]: user1
Mode [0755]:
Add another data mount? [y/N]: n
```

---

### 非対話形式で作成する

CI や手順書に書く場合は、必要な option をすべて指定します。

```sh
./lxcpkg build \
  --rootfs trixie64 \
  --name Debian \
  --output Debian.lxcpkg \
  --package-id com.example.Debian \
  --version 1.0.0 \
  --rootfs-mode volatile \
  --data Debian:/var/hoge:user1:user1:0755
```

`--non-interactive` を指定した場合、不足項目があると対話入力せずにエラー終了します。

```sh
./lxcpkg build \
  --non-interactive \
  --rootfs trixie64 \
  --name Debian \
  --output Debian.lxcpkg
```

short option を使う場合:

```sh
./lxcpkg build \
  -r trixie64 \
  -n Debian \
  -V 1.0.0 \
  -o Debian.lxcpkg
```

---

## build command options

```text
-r, --rootfs=ROOTFS
    Source rootfs directory.

-o, --output=OUTPUT
    Output .lxcpkg file. 必須。

-P, --package-id=PACKAGE_ID
    Package ID.
    未指定時は com.example.<name>。

-n, --name=NAME
    Package name.
    WebUI 側で instance name の初期値として使われます。

-V, --version=VERSION
    Package version.
    未指定時は 1.0.0。

-a, --arch=ARCH
    Target architecture.
    指定可能値: armhf, aarch64。
    未指定時は rootfs 内の ELF binary から自動判定します。
    指定した場合も rootfs の実体と照合し、不一致ならエラーになります。

-m, --rootfs-mode=MODE
    Initial rootfs overlay mode.
    指定可能値: persistent, volatile, snapshot。
    未指定時は volatile。

-c, --compression=COMPRESSION
    Squashfs compression.
    指定可能値: zstd, xz, gzip, lz4, lzo。
    未指定時は zstd。

-B, --block-size=SIZE
    Squashfs block size.
    未指定時は 1M。

-D, --data=SPEC
    Data mount specification.
    複数指定可能。

-e, --exclude=PATTERN
    Additional mksquashfs exclude pattern.
    複数指定可能。

--non-interactive
    不足項目があっても対話入力せず、エラー終了します。

--no-ensure-ssh-host-keys
    Debian / Ubuntu 系 systemd rootfs に OpenSSH server が入っている場合でも、missing host key 生成用 ssh.service drop-in を自動追加しません。

-f, --force
    既存 output file を上書きします。

--keep-workdir
    成功時も temporary build directory を削除せず残します。

-v, --verbose
    実行する外部コマンドなどを表示します。
```

---

## build-download command

`build-download` は、Linux Containers Image Server から rootfs を取得し、そのまま `.lxcpkg` を作成します。

Image Server の index や URL 構造は `lxcpkg` では解釈せず、標準の `lxc-download` template に任せます。
`lxcpkg` 側は、取得済み rootfs を製品向けの squashfs ベース `.lxcpkg` に変換することに集中します。

### Alpine arm64 の例

```sh
sudo ./lxcpkg build-download \
  --dist alpine \
  --release 3.23 \
  --bits 64 \
  --name alpine-3.23 \
  --version 1.0.0 \
  --output alpine-3.23.lxcpkg \
  --preset alpine-appliance
```

同じ内容は short option でも指定できます。

```sh
sudo ./lxcpkg build-download \
  -d alpine \
  -R 3.23 \
  -b 64 \
  -n alpine-3.23 \
  -V 1.0.0 \
  -o alpine-3.23.lxcpkg \
  -p alpine-appliance
```

処理の概要は以下です。

```text
1. /var/tmp 配下に temporary work directory を作成
2. lxc-create -t download で rootfs を取得
3. 生成された LXC config から lxc.rootfs.path を読む
4. bwrap sandbox 内で rootfs に normalize / minimize / network profile を適用
5. 既存の build flow で rootfs.sqfs と manifest.json を作成
6. .lxcpkg archive を作成
```

### Debian / Ubuntu の例

```sh
sudo ./lxcpkg build-download \
  --dist debian \
  --release trixie \
  --bits 64 \
  --name debian-trixie \
  --version 1.0.0 \
  --output debian-trixie.lxcpkg \
  --preset debian-appliance
```

`--network-mode host-configured` は Alpine では default networking service を外します。
Debian / Ubuntu / Fedora などの systemd 系 rootfs では、現時点では blindly に network service を無効化しません。

### 対話モード

`lxc-download` template の対話選択をそのまま使いたい場合は `--interactive` を指定します。

```sh
sudo ./lxcpkg build-download \
  --interactive \
  --bits 64 \
  --name devuan-excalibur \
  --version 1.0.0 \
  --output devuan-excalibur.lxcpkg
```

`--interactive` では `lxc-create` の stdin / stdout / stderr を親端末に接続します。

`--interactive` だけでも作成できますが、`--name` を省略すると package name は `downloaded` になります。WebUI 上で識別しやすくするため、通常は `--name` と `--version` を指定してください。

`--release` は Image Server から取得する OS の release 名です。例: `trixie`, `noble`, `3.23`, `excalibur`。
`--version` は生成する `.lxcpkg` package の version です。OS の release 名ではなく、利用者が管理する package version として `1.0.0`, `1.0.1`, `20260606.1` などを指定します。

---

## build-download command options

```text
-d, --dist=DIST
    Distribution name passed to lxc-download.
    例: alpine, debian, ubuntu, fedora。

-R, --release=RELEASE
    Distribution release passed to lxc-download.
    例: 3.23, trixie, noble, 44。

-b, --bits=BITS
    Target ARM bit width.
    指定可能値: 64, 32。
    64 は arm64、32 は armhf として lxc-download に渡します。

-a, --arch=ARCH
    Target architecture.
    指定可能値: arm64, aarch64, armhf, armv7, armv7l。
    --bits と同時には指定できません。

--interactive
    lxc-download template の対話選択を使用します。

-w, --work-dir=PATH
    Temporary work directory parent.
    未指定時は /var/tmp。

-N, --normalize=PROFILE
    Rootfs normalize profile.
    指定可能値: none, product。
    product では /etc/resolv.conf symlink 対策、machine-id 初期化、tmp/log 掃除を行います。
    変更処理は bwrap sandbox 内で実行されます。

-M, --minimize=PROFILE
    Rootfs minimize profile.
    指定可能値: none, auto, alpine, debian。
    auto は /etc/os-release を見て Alpine / Debian-like を判定します。
    cache / log / tmp の削除は bwrap sandbox 内で実行されます。

--network-mode=MODE
    Container network policy.
    指定可能値: dhcp, host-configured。
    dhcp は rootfs 側の初期設定を尊重します。
    host-configured は host 側 LXC config から IP / DNS を注入する製品運用向けです。

-p, --preset=PRESET
    製品向け rootfs profile preset。
    指定可能値: none, auto-appliance, alpine-appliance, debian-appliance, ubuntu-appliance。
    preset 指定時は normalize / minimize / network-mode の製品向け組み合わせを適用します。

-o, --output=OUTPUT
    Output .lxcpkg file. 必須。

-P, --package-id=PACKAGE_ID
    Package ID.

-n, --name=NAME
    Package name.

-V, --version=VERSION
    Package version.

-m, --rootfs-mode=MODE
    Initial rootfs overlay mode.
    指定可能値: persistent, volatile, snapshot。

-c, --compression=COMPRESSION
    Squashfs compression.

-B, --block-size=SIZE
    Squashfs block size.

-D, --data=SPEC
    Data mount specification.
    複数指定可能。

-e, --exclude=PATTERN
    Additional mksquashfs exclude pattern.
    複数指定可能。

--no-ensure-ssh-host-keys
    Debian / Ubuntu 系 systemd rootfs に OpenSSH server が入っている場合でも、missing host key 生成用 ssh.service drop-in を自動追加しません。

-f, --force
    既存 output file を上書きします。

--keep-workdir
    成功時も temporary work directory を削除せず残します。

-v, --verbose
    実行する外部コマンドなどを表示します。
```

---

## build-tarball command

`build-tarball` は、既に手元にある rootfs tarball から `.lxcpkg` を作成します。

`build-download` は `lxc-create -t download` が使える環境向けですが、CI や社内ミラー、手動ダウンロード済みの `rootfs.tar.xz` / `rootfs.tar.zst` / `rootfs.tar.gz` を使いたい場合は `build-tarball` のほうが単純です。

### 例

```sh
sudo ./lxcpkg build-tarball \
  --tarball rootfs.tar.xz \
  --name alpine-3.23 \
  --version 1.0.0 \
  --arch aarch64 \
  --output alpine-3.23.lxcpkg \
  --preset auto-appliance
```

short option を使う場合:

```sh
sudo ./lxcpkg build-tarball \
  -t rootfs.tar.xz \
  -n alpine-3.23 \
  -V 1.0.0 \
  -a aarch64 \
  -o alpine-3.23.lxcpkg \
  -p auto-appliance
```

処理の概要は以下です。

```text
1. /var/tmp 配下に temporary work directory を作成
2. tarball を rootfs-extract directory に展開
3. archive root または単一の top-level directory から rootfs を検出
4. bwrap sandbox 内で rootfs に normalize / minimize / network profile を適用
5. 既存の build flow で rootfs.sqfs と manifest.json を作成
6. .lxcpkg archive を作成
```

rootfs tarball は、archive root に `etc/passwd` と `etc/group` がある形式、または単一の top-level directory の下に rootfs がある形式を想定します。

### build-tarball command options

```text
-t, --tarball=TARBALL
    Rootfs tarball.
    例: rootfs.tar.xz, rootfs.tar.zst, rootfs.tar.gz, rootfs.tar.bz2。

--work-dir=PATH
    Temporary extraction work directory parent.
    未指定時は /var/tmp。

-N, --normalize=PROFILE
    Rootfs normalize profile.
    指定可能値: none, product。
    変更処理は bwrap sandbox 内で実行されます。

-M, --minimize=PROFILE
    Rootfs minimize profile.
    指定可能値: none, auto, alpine, debian。
    cache / log / tmp の削除は bwrap sandbox 内で実行されます。

--network-mode=MODE
    Container network policy.
    指定可能値: dhcp, host-configured。

-p, --preset=PRESET
    製品向け rootfs profile preset。
    指定可能値: none, auto-appliance, alpine-appliance, debian-appliance, ubuntu-appliance。

-o, --output=OUTPUT
    Output .lxcpkg file. 必須。

-P, --package-id=PACKAGE_ID
    Package ID.

-n, --name=NAME
    Package name.

-V, --version=VERSION
    Package version.

-a, --arch=ARCH
    Target architecture.
    指定可能値: armhf, aarch64。

-m, --rootfs-mode=MODE
    Initial rootfs overlay mode.
    指定可能値: persistent, volatile, snapshot。

-c, --compression=COMPRESSION
    Squashfs compression.

-B, --block-size=SIZE
    Squashfs block size.

-D, --data=SPEC
    Data mount specification.
    複数指定可能。

-e, --exclude=PATTERN
    Additional mksquashfs exclude pattern.
    複数指定可能。

--no-ensure-ssh-host-keys
    Debian / Ubuntu 系 systemd rootfs に OpenSSH server が入っている場合でも、missing host key 生成用 ssh.service drop-in を自動追加しません。

-f, --force
    既存 output file を上書きします。

--keep-workdir
    成功時も temporary work directory を削除せず残します。

-v, --verbose
    実行する外部コマンドなどを表示します。
```


## pack-lxc-dir command

`pack-lxc-dir` は、既に作成済みの LXC directory から `.lxcpkg` を作成します。

例えば、手元で次のように rootfs を取得済みの場合に使います。

```sh
sudo lxc-create -t download -P /var/tmp/lxcdownload -n alpine \
  -- -a arm64 -d alpine -r 3.23
```

`.lxcpkg` 化は以下です。

```sh
sudo ./lxcpkg pack-lxc-dir \
  --lxc-dir /var/tmp/lxcdownload/alpine \
  --name alpine-3.23 \
  --version 1.0.0 \
  --arch aarch64 \
  --output alpine-3.23.lxcpkg \
  --preset auto-appliance
```

`pack-lxc-dir` は `<lxc-dir>/config` を読み、`lxc.rootfs.path` から rootfs directory を見つけます。
download template 由来の LXC config は製品側へそのまま持ち込まず、rootfs path の検出と source 情報の参考にだけ使います。

---

## pack-lxc-dir command options

```text
-L, --lxc-dir=LXC_DIR
    LXC directory containing config and rootfs.

-o, --output=OUTPUT
    Output .lxcpkg file. 必須。

-P, --package-id=PACKAGE_ID
    Package ID.

-n, --name=NAME
    Package name.

-V, --version=VERSION
    Package version.

-a, --arch=ARCH
    Target architecture.
    指定可能値: armhf, aarch64。

-m, --rootfs-mode=MODE
    Initial rootfs overlay mode.

-N, --normalize=PROFILE
    Rootfs normalize profile.
    指定可能値: none, product。

-M, --minimize=PROFILE
    Rootfs minimize profile.
    指定可能値: none, auto, alpine, debian。

--network-mode=MODE
    Container network policy.
    指定可能値: dhcp, host-configured。

-c, --compression=COMPRESSION
    Squashfs compression.

-B, --block-size=SIZE
    Squashfs block size.

-D, --data=SPEC
    Data mount specification.
    複数指定可能。

-e, --exclude=PATTERN
    Additional mksquashfs exclude pattern.
    複数指定可能。

--no-ensure-ssh-host-keys
    Debian / Ubuntu 系 systemd rootfs に OpenSSH server が入っている場合でも、missing host key 生成用 ssh.service drop-in を自動追加しません。

-f, --force
    既存 output file を上書きします。

--keep-workdir
    成功時も temporary build directory を削除せず残します。

-v, --verbose
    実行する外部コマンドなどを表示します。
```

---

## rebuild command

`rebuild` は、元の `.lxcpkg` と WebUI からダウンロードした `.lxcdev` 開発アーカイブを組み合わせて、新しい `.lxcpkg` を作成します。

用途:

```text
1. PC で base .lxcpkg を作成する
2. 実機 WebUI に upload / install する
3. snapshot mode の instance 上で開発・調整する
4. WebUI から .lxcdev をダウンロードする
5. PC 上で base .lxcpkg + .lxcdev から更新版 .lxcpkg を rebuild する
```

`.lxcdev` には rootfs 全体は含まれません。
保存済み overlay snapshot、LXC config、instance metadata、package manifest、lxcdev manifest を含む差分アーカイブです。

そのため `rebuild` には、`.lxcdev` の元になった base `.lxcpkg` が必要です。

---

### 基本例

```sh
sudo ./lxcpkg rebuild \
  --base Debian-1.0.0.lxcpkg \
  --dev Debian-1.0.0-Debian.lxcdev \
  --output Debian-rebuilt.lxcpkg
```

`rebuild` は Linux の mount 機能を使います。
通常は `sudo` 付きで実行してください。

出力例:

```text
lxcpkg rebuild options:
  base:            Debian-1.0.0.lxcpkg
  dev:             Debian-1.0.0-Debian.lxcdev
  output:          Debian-rebuilt.lxcpkg
  packageId:       com.example.Debian
  name:            Debian
  baseVersion:     1.0.0
  version:         1.0.0+lxcdev.20260530.2325
  arch:            aarch64
  rootfsMode:      volatile
  compression:     zstd
  blockSize:       1M
  clean:           true
  scrub:           true
  pruneEmptyDirs:  true
Created package: Debian-rebuilt.lxcpkg
```

---

### version の扱い

`--version` を指定した場合は、その version をそのまま使用します。

```sh
sudo ./lxcpkg rebuild \
  --base Debian-1.0.0.lxcpkg \
  --dev Debian-1.0.0-Debian.lxcdev \
  --version 1.0.1 \
  --output Debian-1.0.1.lxcpkg
```

`--version` を省略した場合、base package の version が `MAJOR.MINOR.PATCH` 形式なら、UTC 分単位の build metadata を付けます。

```text
1.0.0 -> 1.0.0+lxcdev.YYYYMMDD.HHMM
```

例:

```text
1.0.0 -> 1.0.0+lxcdev.20260530.2325
```

base version が `1.0.0-dev` や `v1.0.0` のように `MAJOR.MINOR.PATCH` 形式でない場合は、version を変更せず、warning を表示します。

正式配布用の version を明確にしたい場合は、`--version` を明示してください。

---

### rebuild の内部処理

`rebuild` は、単純に overlay snapshot を base rootfs へ copy するわけではありません。
削除済みファイルや opaque directory を正しく反映するため、overlayfs の merged view を作ってから `mksquashfs` します。

処理の概要:

```text
1. base .lxcpkg を unzip
2. .lxcdev を unzip
3. manifest.json と lxcdev-manifest.json を読む
4. base rootfs.sqfs の SHA256 を照合
5. overlay-snapshot.tar.zst の SHA256 を照合
6. rootfs.sqfs を squashfs として read-only mount
7. overlay-snapshot.tar.zst を upperdir に展開
8. overlayfs で merged rootfs を mount
9. merged rootfs に release cleanup を実行
10. merged rootfs から新しい rootfs.sqfs を作成
11. 新しい manifest.json を作成
12. manifest.json + rootfs.sqfs を zip 化して .lxcpkg を作成
```

### rebuild の release cleanup

`rebuild` で作成する `.lxcpkg` は配布用の full package になるため、標準で release cleanup を実行します。

標準では、overlayfs の merged rootfs を作った後、`mksquashfs` の前に不要物・実機固有情報を削除します。主な対象は次の通りです。

```text
/var/cache/apt/archives/*
/var/lib/apt/lists/*
/tmp/*
/var/tmp/*
/run/*
/var/run/*
/var/log/*
/root/.cache/*
/root/.npm/*
/root/.pnpm-store/*
/root/.composer/cache/*
/home/*/.cache/pip/*
/home/*/.cache/pypoetry/*
/home/*/.cache/yarn/*
/home/*/.cache/pnpm/*
/home/*/.npm/*
/home/*/.pnpm-store/*
/home/*/.composer/cache/*
__pycache__/
*.pyc
*.pyo
/var/lib/dbus/machine-id
/etc/ssh/ssh_host_*_key
/etc/ssh/ssh_host_*_key.pub
/root/.bash_history
/root/.wget-hsts
```

`/etc/machine-id` は systemd 系 rootfs での扱いを考慮し、削除ではなく空ファイル化します。これにより、初回起動時に機器ごとの machine-id を再生成しやすい状態にします。

full rootfs package では、`/tmp`, `/var/tmp`, `/run`, `/var/run`, `/var/log`, `/etc/ssh` などの慣習的なディレクトリは、空になっても標準では削除しません。空ディレクトリ削除の対象は cache/artifact 系に絞っています。

実機固有情報を意図的に `.lxcpkg` へ含めたい場合は、明示的に opt-out します。

```sh
sudo ./lxcpkg rebuild \
  --base Debian-1.0.0.lxcpkg \
  --dev Debian-1.0.0-Debian.lxcdev \
  --version 1.0.1 \
  --output Debian-1.0.1.lxcpkg \
  --no-release-clean
```

互換性確認として、以下が一致しない場合はエラーになります。

```text
package name
package version
architecture
image file name
base image SHA256
overlay snapshot SHA256
```

`.lxcdev` に data mount の中身が含まれる形式は、現在は未対応です。
`dataMountsIncluded=true` の `.lxcdev` は拒否します。

---

## rebuild command options

```text
--base=BASE
    Base .lxcpkg file.
    .lxcdev の元になった package を指定します。

--dev=DEV
    Development .lxcdev archive.
    WebUI の Download .lxcdev で取得した archive を指定します。

-o, --output=OUTPUT
    Output .lxcpkg file. 必須。
    未指定時は <name>-<version>.lxcpkg。

--version=VERSION
    Package version for rebuilt package.
    未指定時は、base version が MAJOR.MINOR.PATCH 形式なら +lxcdev.YYYYMMDD.HHMM を付けます。

--rootfs-mode=MODE
    Rootfs overlay mode for rebuilt package.
    指定可能値: persistent, volatile, snapshot。
    未指定時は base package の rootfsMode を引き継ぎます。

-c, --compression=COMPRESSION
    Squashfs compression.
    指定可能値: zstd, xz, gzip, lz4, lzo。
    未指定時は zstd。

-B, --block-size=SIZE
    Squashfs block size.
    未指定時は 1M。

-e, --exclude=PATTERN
    Additional mksquashfs exclude pattern.
    複数指定可能。

--no-clean
    apt/cache/log/tmp, language runtime cache, Python bytecode などの削除を無効にします。

--no-scrub
    machine-id, SSH host key, shell history などの実機固有情報削除を無効にします。

--no-prune-empty-dirs
    release cleanup 後の空ディレクトリ削除を無効にします。

--no-release-clean
    標準の release cleanup を無効にします。--no-clean --no-scrub --no-prune-empty-dirs と同等です。

--no-ensure-ssh-host-keys
    Debian / Ubuntu 系 systemd rootfs に OpenSSH server が入っている場合でも、missing host key 生成用 ssh.service drop-in を自動追加しません。

-f, --force
    既存 output file を上書きします。

--keep-workdir
    成功時も temporary rebuild directory を削除せず残します。

-v, --verbose
    実行する外部コマンドなどを表示します。
```

---

## rootfs architecture 自動判定

`--arch` 未指定時、rootfs 内の代表的な ELF binary から architecture を自動判定します。

判定候補:

```text
/bin/sh
/usr/bin/env
/usr/bin/bash
/bin/bash
/bin/busybox
/sbin/init
/usr/lib/systemd/systemd
```

対応 architecture は次の 2 つです。

```text
aarch64
armhf
```

それ以外はエラーです。

`armhf` は ELF header が ARM であることに加え、rootfs 内の hard-float loader / library directory を確認します。

```text
/lib/ld-linux-armhf.so.3
/lib/arm-linux-gnueabihf
/usr/lib/arm-linux-gnueabihf
```

`armel` や x86_64 rootfs は対象外です。

---

## rootfsMode

`rootfsMode` は、作成される instance の rootfs overlay 初期モードです。

### persistent

storage-backed overlay を使います。
rootfs 差分は instance の `overlay/` に保持されます。

```json
"rootfsMode": "persistent"
```

### volatile

tmpfs 上の overlay を使います。
停止時に rootfs 差分は破棄されます。

運用時に rootfs を汚したくない場合はこちらを使います。

```json
"rootfsMode": "volatile"
```

### snapshot

tmpfs overlay を使いつつ、WebUI 側で save / restore できる開発向けモードです。

```json
"rootfsMode": "snapshot"
```

---

## data mount

アプリの永続データ領域を rootfs overlay から分離したい場合、data mount を指定します。

形式:

```text
--data name:target[:uid-or-user[:gid-or-group[:mode]]]
```

例:

```sh
--data Debian:/var/Debian:user1:user1:0755
```

この指定は、manifest では以下のようになります。

```json
{
  "name": "Debian",
  "target": "/var/Debian",
  "uid": 1000,
  "gid": 1000,
  "mode": "0755"
}
```

`uid-or-user` / `gid-or-group` には数値または名前を指定できます。
名前を指定した場合、rootfs 内の以下から数値 ID を解決します。

```text
<rootfs>/etc/passwd
<rootfs>/etc/group
```

未指定時の default:

```text
uid  = 0
gid  = 0
mode = 0755
```

---

## data mount target の許可範囲

許可される target:

```text
/opt/...
/home/...
/var/lib/...
/var/<app>
/var/<app>/...
```

例:

```text
/opt/testapp-data
/var/lib/testapp
/var/hoge
/home/user1/appdata
```

拒否される target:

```text
/
/etc
/usr
/var
/root
/lib
/bin
/sbin
/dev
/proc
/sys
/run
/boot
```

`/var` 配下でも、以下の OS 管理領域は拒否します。

```text
/var/backups
/var/cache
/var/lib
/var/local
/var/lock
/var/log
/var/mail
/var/opt
/var/run
/var/spool
/var/tmp
```

ただし `/var/lib/...` は許可します。

---

## data mount mode

許可される mode は以下です。

```text
0700
0750
0755
0770
0775
```

`755` のような 3 桁指定は `0755` に正規化されます。

`0777` は許可しません。

---

## squashfs 作成時の除外

`lxcpkg` は `mksquashfs` 実行時に、cache や一時ファイルを rootfs image へ入れないように除外します。

標準の除外 pattern:

```text
var/cache/apt/archives/*
var/cache/apt/*
var/lib/apt/lists/*
var/tmp/*
var/run/*
run/*
tmp/*
usr/lib/modules/*
lib/modules/*
root/.bash_history
home/user1/.bash_history
usr/bin/qemu-arm-static
boot/*
```

追加で除外したい場合は `--exclude` を使います。

```sh
./lxcpkg build \
  --rootfs trixie64 \
  --name Test \
  --output Test.lxcpkg \
  --exclude 'var/log/*' \
  --exclude 'root/.cache/*'
```

rootfs directory 自体は変更しません。
あくまで squashfs に含めないだけです。

---

## output file の扱い

`.lxcpkg` / `.lxcdelta` を作成する command では、`--output` または `-o` が必須です。
指定が無い場合は、download / extract / squashfs 作成などを開始する前にエラー終了します。
`rewrite-metadata` も既存 `.lxcpkg` とは別の出力先を必須とし、入力 file と同じ path への in-place rewrite は拒否します。

既存 output file がある場合、`--force` なしではエラー終了します。

```text
output file already exists: /path/to/Debian.lxcpkg
```

この check は `mksquashfs` 実行前に行われます。
そのため、既存 file があるだけで重い squashfs 作成が走ることはありません。

上書きしたい場合:

```sh
./lxcpkg build \
  --rootfs trixie64 \
  --name Debian \
  --output Debian.lxcpkg \
  --force
```

---

## temporary build directory

`build` 中は `/tmp/lxcpkg-<pid>-<index>` のような temporary build directory を作成します。

`rebuild` 中は `/tmp/lxcpkg-rebuild-<pid>-<index>` のような temporary rebuild directory を作成します。

`rewrite-metadata` 中は `/tmp/lxcpkg-rewrite-metadata-<pid>-<index>` のような temporary rewrite-metadata directory を作成します。

成功時:

```text
--keep-workdir なし:
  temporary build directory を削除

--keep-workdir あり:
  temporary build directory を残す
```

失敗時:

```text
temporary build directory を残す
確認後に手動削除する案内を表示
```

例:

```text
Temporary build directory was kept for inspection: /tmp/lxcpkg-2707-0
Remove it manually after checking: rm -rf /tmp/lxcpkg-2707-0
```

`rebuild` の場合:

```text
Temporary rebuild directory was kept for inspection: /tmp/lxcpkg-rebuild-9682-0
Remove it manually after checking: rm -rf /tmp/lxcpkg-rebuild-9682-0
```

`rewrite-metadata` の場合:

```text
Temporary rewrite-metadata directory was kept for inspection: /tmp/lxcpkg-rewrite-metadata-9682-0
Remove it manually after checking: rm -rf /tmp/lxcpkg-rewrite-metadata-9682-0
```

---

## 生成される manifest.json の例

```json
{
  "packageId": "com.example.Debian",
  "name": "Debian",
  "version": "1.0.0",
  "arch": "aarch64",
  "rootfsMode": "volatile",
  "image": {
    "file": "rootfs.sqfs",
    "sha256": "7cf7d6ea86a523e86178f571001f0000dda9799badf527661b41539313d46a9a"
  },
  "dataMounts": [
    {
      "name": "hoge",
      "target": "/var/hoge",
      "uid": 1000,
      "gid": 1000,
      "mode": "0755"
    }
  ]
}
```

`image.sha256` は `rootfs.sqfs` の SHA256 です。
WebUI / AppServer 側では install 時にこの値を検証します。

---

## 動作確認例

### package の中身確認

```sh
unzip -l Debian.lxcpkg
```

```text
Archive:  Debian.lxcpkg
  Length      Date    Time    Name
---------  ---------- -----   ----
      420  2026-05-30 16:20   manifest.json
 39448576  2026-05-30 16:20   rootfs.sqfs
---------                     -------
 39448996                     2 files
```

### manifest 確認

```sh
unzip -p Debian.lxcpkg manifest.json
```

### SHA256 確認

```sh
rm -rf /tmp/lxcpkg-check
mkdir -p /tmp/lxcpkg-check
cd /tmp/lxcpkg-check
unzip /path/to/Debian.lxcpkg
sha256sum rootfs.sqfs
cat manifest.json
```

`sha256sum rootfs.sqfs` と `manifest.json` の `image.sha256` が一致すれば OK です。

### rebuild した package の確認

```sh
unzip -l Debian-rebuilt.lxcpkg
unzip -p Debian-rebuilt.lxcpkg manifest.json | jq .
```

期待する中身:

```text
manifest.json
rootfs.sqfs
```

version を省略した場合、manifest には次のような version が入ります。

```json
"version": "1.0.0+lxcdev.20260530.2325"
```

---

## WebUI / AppServer 側での確認

作成した `.lxcpkg` を WebUI から upload し、instance 作成後に detail を確認します。

確認ポイント:

```text
rootfsMode
dataMounts
source
target
owner
mode
exists
```

host 側確認例:

```sh
ls -ld /var/lib/lxc/<instance>/data/<dataMountName>
```

container 起動後:

```sh
lxc-start -n <instance>
lxc-attach -n <instance> -- ls -ld /var/hoge
lxc-attach -n <instance> -- su - user1 -c 'echo ok > /var/hoge/from-user1'
cat /var/lib/lxc/<instance>/data/Debian/from-user1
```

`ok` が見えれば、data mount の bind mount と書き込み権限は正常です。

`rootfsMode=volatile` の場合、停止後に rootfs overlay は消え、data mount は残ります。

```sh
lxc-stop -n <instance>
ls -ld /run/lxc-volatile/<instance>
ls -l /var/lib/lxc/<instance>/data/Debian/from-user1
```

期待:

```text
/run/lxc-volatile/<instance> は存在しない
data/Debian/from-user1 は残る
```

---

## rewrite-metadata command

`rewrite-metadata` は、既存 `.lxcpkg` の rootfs image を作り直さずに `manifest.json` の metadata だけを書き換え、新しい `.lxcpkg` を作成します。

主な用途は、Debian / Alpine などの base package を元にして、HTTP server appliance や MODBUS appliance など、別 package lineage の初期パッケージを作りたい場合です。

変更できる metadata は以下です。

```text
packageId
name
version
```

変更しないものは以下です。

```text
rootfs.sqfs
rootfs.sqfs の SHA256
arch
rootfsMode
dataMounts
rootfs の中身
```

### 基本例

```sh
./lxcpkg rewrite-metadata \
  --input debian-trixie-base.lxcpkg \
  --output http-appliance-1.0.0.lxcpkg \
  --package-id com.example.http-appliance \
  --name http-appliance \
  --version 1.0.0
```

この例では、元の rootfs はそのまま使い、manifest 上の package identity だけを新しい HTTP server appliance 用に変更します。

`packageId` を変更すると、更新系列が変わります。新しい `packageId` に書き換えた `.lxcpkg` は、旧 `packageId` でインストール済みのインスタンスに対する `replace-base` 用更新パッケージとしては使えません。これは、意図しない別系列 package への更新を防ぐための挙動です。

既存インスタンスを更新したい場合は、既存インスタンスの `packageId` と一致する `.lxcpkg` を作成してください。新規 appliance として心機一転したい場合は、`packageId`, `name`, `version` をまとめて変更する使い方を推奨します。

### rewrite-metadata command options

```text
-i, --input=INPUT
    Input .lxcpkg file. 必須。

-o, --output=OUTPUT
    Output .lxcpkg file. 必須。
    入力と同じ path への in-place rewrite は拒否します。

-P, --package-id=PACKAGE_ID
    New package ID.
    指定した場合、manifest.json の packageId をこの値に変更します。

-n, --name=NAME
    New package name.
    指定した場合、manifest.json の name をこの値に変更します。

-V, --version=VERSION
    New package version.
    指定した場合、manifest.json の version をこの値に変更します。

-f, --force
    既存 output file を上書きします。

--keep-workdir
    成功時も temporary rewrite-metadata directory を削除せず残します。

-v, --verbose
    実行する外部コマンドなどを表示します。
```

`--package-id`, `--name`, `--version` のうち少なくとも 1 つは指定してください。指定しなかった metadata は元の `.lxcpkg` の値を引き継ぎます。


---

## 注意点

- このツールは rootfs directory を作成するものではありません。
- rootfs は事前に debootstrap / mmdebstrap / 手作業などで準備してください。
- rootfs directory 自体は変更しません。
- `rebuild` は Linux の overlayfs mount を使うため、Linux 上の root 権限が必要です。
- `rewrite-metadata` は rootfs を変更せず、既存 `.lxcpkg` の manifest metadata だけを書き換えます。
- `mksquashfs` / `zip` / `unzip` / `tar` / `zstd` / `mount` / `umount` は外部コマンドとして実行します。
- 対応 architecture は `armhf` と `aarch64` のみです。
- data mount target は AppServer 側の validation と合わせる必要があります。
- `/var/<app>` を使う場合、AppServer 側も `/var/<app>` data mount を許可する版である必要があります。

---

## delta command

`delta` は、元の `.lxcpkg` と WebUI からダウンロードした `.lxcdev` 開発アーカイブを組み合わせて、base image に対する差分 `.lxcdelta` を作成します。

`rebuild` と異なり、merged rootfs 全体は作成しません。`.lxcdev` に含まれる overlayfs upperdir snapshot を展開し、その upperdir をそのまま `delta.sqfs` として squashfs 化します。overlayfs の native whiteout を維持するため、削除差分も delta image に残ります。

### 基本例

```sh
sudo ./lxcpkg delta \
  --base Debian-1.0.0.lxcpkg \
  --dev Debian-1.0.0-Debian.lxcdev \
  --version 1.0.1 \
  --output Debian-1.0.1.lxcdelta
```

生成される `.lxcdelta` は zip archive です。中身は次の 2 ファイルです。

```text
manifest.json
delta.sqfs
```

### release cleanup

`.lxcdelta` は配布用差分として使う想定のため、`delta` command は標準で release cleanup を実行します。

標準では、`.lxcdev` の overlay snapshot を展開した後、`mksquashfs` の前に upperdir から次のような不要物・実機固有情報を削除します。

```text
/var/cache/apt/archives/*
/var/lib/apt/lists/*
/tmp/*
/var/tmp/*
/run/*
/var/run/*
/var/log/*
/root/.cache/*
/root/.npm/*
/root/.pnpm-store/*
/root/.composer/cache/*
/home/*/.cache/pip/*
/home/*/.cache/pypoetry/*
/home/*/.cache/yarn/*
/home/*/.cache/pnpm/*
/home/*/.npm/*
/home/*/.pnpm-store/*
/home/*/.composer/cache/*
__pycache__/
*.pyc
*.pyo
/etc/machine-id
/var/lib/dbus/machine-id
/etc/ssh/ssh_host_*_key
/etc/ssh/ssh_host_*_key.pub
/root/.bash_history
/root/.wget-hsts
```

cleanup 後、対象を絞って空ディレクトリも削除します。

注意点:

- cleanup は merged rootfs ではなく、展開後の overlay upperdir に対して実行します。
- character device などの special entry は削除しません。
- overlayfs native whiteout を消すと base 側のファイルが復活するため、whiteout は保持します。
- `node_modules`, Python venv 本体, `vendor`, `build`, `target`, `*.o`, `*.a`, `*.jar`, `*.class`, `*.so` は標準 cleanup 対象にしません。
- `/var/cache/debconf` と `/var/lib/dpkg` は package 状態に関係するため、標準 cleanup 対象にしません。

検証用に cleanup しない状態を残したい場合は、明示的に opt-out します。

```sh
sudo ./lxcpkg delta \
  --base Debian-1.0.0.lxcpkg \
  --dev Debian-1.0.0-Debian.lxcdev \
  --version 1.0.1 \
  --output Debian-1.0.1.lxcdelta \
  --no-release-clean
```

### delta command options

```text
--base=BASE
    Base .lxcpkg file.

--dev=DEV
    Development .lxcdev archive.

-o, --output=OUTPUT
    Output .lxcdelta file. 必須。

--version=VERSION
    Package version for delta package.

-c, --compression=COMPRESSION
    Squashfs compression.
    指定可能値: zstd, xz, gzip, lz4, lzo。
    未指定時は zstd。

-B, --block-size=SIZE
    Squashfs block size.
    未指定時は 1M。

-e, --exclude=PATTERN
    Additional mksquashfs exclude pattern.
    複数指定可能。

--no-clean
    apt/cache/log/tmp, language runtime cache, Python bytecode などの削除を無効にします。

--no-scrub
    machine-id, SSH host key, shell history などの実機固有情報削除を無効にします。

--no-prune-empty-dirs
    release cleanup 後の空ディレクトリ削除を無効にします。

--no-release-clean
    標準の release cleanup を無効にします。--no-clean --no-scrub --no-prune-empty-dirs と同等です。

-f, --force
    既存 output file を上書きします。

--keep-workdir
    成功時も temporary delta directory を削除せず残します。

-v, --verbose
    実行する外部コマンドなどを表示します。
```


### interactive mode と distribution / release の指定

`build-download --interactive` では、Image Server の一覧から対話的に distribution / release を選択できます。

`--dist` / `-d` や `--release` / `-R` を併用すると、対話モードでも取得元の一部を事前指定できます。たとえば `-d alpine --interactive` とすると distribution は Alpine に固定し、release だけを対話的に選択できます。

```sh
sudo lxcpkg build-download \
  --interactive \
  -d alpine \
  -b 32 \
  -n alpine-armhf \
  -V 1.0.0 \
  -o alpine-armhf.lxcpkg
```

`--dist` は Image Server の distribution 名、`--release` は Image Server の release 名です。`--version` / `-V` は生成する `.lxcpkg` パッケージのバージョンであり、OS の release 名ではありません。
