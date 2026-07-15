# MCXboxBroadcast Pelican/Pterodactyl自動更新Egg 設計

## 目的

MCXboxBroadcast StandaloneをPelican PanelとPterodactyl Panelの両方で実行できるEggを提供する。サーバー起動時に公式GitHub Releasesの最新版を確認し、新しいReleaseがある場合だけJarを安全に更新する。

## 背景

公式の`egg-m-c-xbox-broadcast.json`は2026年4月27日にPterodactylの`PTDL_v2`からPelicanの`PLCN_v3`へ変更された。両形式は起動コマンド、変数ルール、メタデータなどの構造が異なるため、単一JSONでの相互互換は目指さない。

## スコープ

- Pelican用Eggを維持する。
- Pterodactyl用Eggを別ファイルとして追加する。
- 公式`MCXboxBroadcast/Broadcaster`のStandalone Jarのみを取得する。
- `AUTO_UPDATE`を既定で有効にし、Panelから無効化できるようにする。
- 更新中の通信障害や不正なダウンロードから既存Jarを保護する。
- `config.yml`、認証情報、セッションデータを保持する。

## 非スコープ

- Panelへインポート済みのEgg定義をPterodactyl側で自動更新する管理機能。
- GitHub Releases APIの利用。
- プレリリース、任意タグ、任意Jar URLの選択。
- 新しいJarが正常に起動しなかった場合の自動ダウングレード。
- MCXboxBroadcast本体のソースコード変更。

## 成果物

| ファイル | 対象 | 形式 |
| --- | --- | --- |
| `egg-m-c-xbox-broadcast.json` | Pelican Panel | `PLCN_v3` |
| `egg-m-c-xbox-broadcast-pterodactyl.json` | Pterodactyl Panel | `PTDL_v2` |

Pelican Eggの`meta.update_url`はフォーク上のPelican Eggを指す。これにより、upstreamのPelican Eggで独自の自動更新ロジックが上書きされることを防ぐ。Pterodactyl Eggの`meta.update_url`は`null`とする。

## 共通ランタイム設定

- Java 21を使用する。
- Jar名は`SERVER_JARFILE`で指定し、既定値を`MCXboxBroadcastStandalone.jar`とする。
- `AUTO_UPDATE`は真偽値として公開し、既定値を`1`とする。
- Java起動コマンドは`java -Xms128M -Xmx{{SERVER_MEMORY}}M -jar {{SERVER_JARFILE}}`とする。
- 停止コマンドはStandaloneが受け付ける`exit`とする。
- 起動完了判定は`Creation of Xbox LIVE session was successful!`を維持する。
- Panelごとに公式のJava 21およびinstallerイメージを使用する。

## 更新判定

最新版の固定入口として次を使用する。

```text
https://github.com/MCXboxBroadcast/Broadcaster/releases/latest/download/MCXboxBroadcastStandalone.jar
```

起動時にHTTP HEADリクエストを送り、最初の`Location`ヘッダーからRelease固有のダウンロードURLを取得する。最終的なCDN URLは署名や有効期限によって変化し得るため、全リダイレクトを追跡した最終URLは比較に使用しない。

取得したRelease固有URLを`.mcxboxbroadcast-release-url`に保存し、次回起動時の比較対象にする。保存済みURLと同じでJarが存在する場合、ダウンロードを省略する。保存済みURLと異なる場合、状態ファイルがない場合、またはJarがない場合は更新を試みる。

`AUTO_UPDATE=0`の場合はネットワークへ接続せず、既存Jarをそのまま起動する。

## 更新フロー

1. `AUTO_UPDATE`を確認する。
2. 有効な場合、最新版入口の最初のリダイレクト先を取得する。
3. 保存済みURLおよびJarの有無から更新要否を決める。
4. 更新が必要な場合、同じディレクトリの一時ファイルへJarをダウンロードする。
5. Java 21付属の`jar tf`で一時ファイルを検証する。
6. 検証成功後に限り、一時ファイルを`SERVER_JARFILE`へ移動する。
7. Jar置換後に状態ファイルを更新する。
8. `exec java ...`でMCXboxBroadcastを起動する。

更新処理はEggの起動コマンド内に自己完結させ、外部の更新スクリプトを起動時に取得しない。PelicanとPterodactylの起動コマンドには同じシェルロジックを使用する。

## インストール

インストールスクリプトは公式の最新版入口からStandalone Jarを`/mnt/server`へダウンロードする。ダウンロードには失敗判定、接続タイムアウト、全体タイムアウト、再試行を設定する。

インストール時にRelease固有URLを取得できた場合は状態ファイルにも保存する。取得できなかった場合でもJarのダウンロードが成功していればインストールを完了し、次回起動時に更新判定を再試行する。

## 障害時の動作

- HEADリクエスト失敗: 既存Jarがあれば警告を表示して起動する。
- ダウンロード失敗: 一時ファイルを削除し、既存Jarを起動する。
- Jar検証失敗: 一時ファイルを削除し、既存Jarを起動する。
- 状態ファイル書き込み失敗: 更新済みJarを起動するが警告を表示し、次回起動時に再確認する。
- Jarが存在しない状態で更新取得にも失敗: 明確なエラーを表示して非ゼロ終了する。
- 更新成功後にMCXboxBroadcast自体が起動失敗: 自動ロールバックは行わない。保存済み設定や認証データは変更しない。

すべての更新ログには`[MCXboxBroadcast Updater]`を付ける。更新なし、更新開始、更新成功、フォールバック起動、致命的失敗を区別できるメッセージにする。

## 安全性

- `curl --fail --location`によりHTTPエラーページをJarとして保存しない。
- 接続タイムアウト、全体タイムアウト、最大3回の再試行を設定する。
- ダウンロード先を本番Jarとは別の一時ファイルにする。
- `jar tf`が成功するまで既存Jarを置換しない。
- 一時ファイルと本番Jarを同一ディレクトリに置き、検証後の移動を同一ファイルシステム内で行う。
- Release URLとJarファイル名は固定し、ユーザー入力からダウンロードURLを組み立てない。

## Panel固有差分

### Pelican

- `meta.version`は`PLCN_v3`。
- `startup_commands.Default`に共通起動ロジックを設定する。
- 変数の`rules`は配列形式を使用する。
- `ghcr.io/pelican-eggs/yolks:java_21`と`ghcr.io/pelican-eggs/installers:alpine`を使用する。
- 現行EggのUUID、画像、タグを維持する。

### Pterodactyl

- `meta.version`は`PTDL_v2`。
- `startup`に共通起動ロジックを設定する。
- 変数の`rules`はパイプ区切り文字列、`field_type`は`text`を使用する。
- `ghcr.io/pterodactyl/yolks:java_21`と`ghcr.io/pterodactyl/installers:alpine`を使用する。
- Pelican専用のUUID、画像、タグ、複数起動コマンド構造は含めない。

## テスト

### 静的検証

- 両ファイルがJSONとして解析できる。
- Pelicanが`PLCN_v3`、Pterodactylが`PTDL_v2`の必須構造を持つ。
- Panel固有イメージ、起動フィールド、変数ルール形式が正しい。
- 両Eggの更新入口、Jar名、更新フロー、Java引数が一致する。

### 更新ロジック

- `AUTO_UPDATE=0`ではネットワークアクセスを行わない。
- 保存済みURLが最新でJarが存在する場合はダウンロードしない。
- Release固有URLが変わった場合は更新する。
- 状態ファイルがない場合は更新する。
- Jarがない場合は更新する。
- HEAD、ダウンロード、Jar検証の各失敗時に既存Jarを保持する。
- Jarがなく取得も失敗した場合は非ゼロ終了する。
- 成功時のみ状態ファイルを新しいURLへ更新する。

外部通信と`jar`コマンドをテスト用スタブへ差し替え、各分岐を再現可能にする。

### コンテナ検証

- Pterodactyl Java 21イメージで起動ロジックのスモークテストを行う。
- 利用可能であればPelican Java 21イメージでも同じテストを行う。
- 公式最新Release Jarを実際にダウンロードし、`jar tf`で検証する。

Panel実機へのインポートは自動テストの範囲外とし、JSON構造と公式コンテナでの挙動を実装側の完了条件とする。

## 完了条件

- 2つのEggをそれぞれ対応Panelへインポートできる構造になっている。
- 新規インストールで公式Standalone Jarを取得できる。
- 起動時に新Releaseのみをダウンロードする。
- 更新チェックまたは更新に失敗しても既存Jarが破壊されない。
- 自動更新をPanel変数から無効化できる。
- 設定および認証データがJar更新の対象外になっている。
- 静的検証、更新ロジックテスト、Pterodactylコンテナスモークテストが成功する。
