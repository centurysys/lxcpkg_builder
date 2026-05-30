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

このツールは汎用 LXC パッケージャではありません。
弊社機器の WebUI / AppServer の `.lxcpkg` 仕様に合わせた専用ツールです。

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

`lxcpkg` は以下の外部コマンドを使用します。

- `mksquashfs`
- `zip`

Debian / Ubuntu 系では、概ね以下で入ります。

```sh
sudo apt install squashfs-tools zip
```

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

---

## build command options

```text
--rootfs=ROOTFS
    Source rootfs directory.

-o, --output=OUTPUT
    Output .lxcpkg file.

--package-id=PACKAGE_ID
    Package ID.
    未指定時は com.example.<name>。

--name=NAME
    Package name.
    WebUI 側で instance name の初期値として使われます。

--version=VERSION
    Package version.
    未指定時は 1.0.0。

--arch=ARCH
    Target architecture.
    指定可能値: armhf, aarch64。
    未指定時は rootfs 内の ELF binary から自動判定します。
    指定した場合も rootfs の実体と照合し、不一致ならエラーになります。

--rootfs-mode=MODE
    Initial rootfs overlay mode.
    指定可能値: persistent, volatile, snapshot。
    未指定時は volatile。

--compression=COMPRESSION
    Squashfs compression.
    指定可能値: zstd, xz, gzip, lz4, lzo。
    未指定時は zstd。

--block-size=SIZE
    Squashfs block size.
    未指定時は 1M。

--data=SPEC
    Data mount specification.
    複数指定可能。

--exclude=PATTERN
    Additional mksquashfs exclude pattern.
    複数指定可能。

--non-interactive
    不足項目があっても対話入力せず、エラー終了します。

-f, --force
    既存 output file を上書きします。

--keep-workdir
    成功時も temporary build directory を削除せず残します。

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

build 中は `/tmp/lxcpkg-<pid>-<index>` のような temporary build directory を作成します。

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

## 注意点

- このツールは rootfs directory を作成するものではありません。
- rootfs は事前に debootstrap / mmdebstrap / 手作業などで準備してください。
- rootfs directory 自体は変更しません。
- `mksquashfs` と `zip` は外部コマンドとして実行します。
- 対応 architecture は `armhf` と `aarch64` のみです。
- data mount target は AppServer 側の validation と合わせる必要があります。
- `/var/<app>` を使う場合、AppServer 側も `/var/<app>` data mount を許可する版である必要があります。
