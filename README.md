# Window Arrange

Swift / SwiftUIで作成したmacOS用ウィンドウ配置アプリです。外部アプリ、プラグイン、Swift Packageの外部依存はありません。

## できること

- グローバルショートカットの割り当て・変更・解除。左右上下の半分、四隅の¼、画面いっぱい、中央、次のモニター、最小化、フルスクリーン切替に対応。
- 名前付きSnapshotの保存、プレビュー、名前変更、削除。
- 複数アプリの位置・サイズ・モニター・最小化状態をまとめて記録・復元。
- **Spacesの所属の記録・復元（実験機能）**。macOS内蔵のシステムAPIをSwiftから直接呼び出します。
- Snapshot保存と選択中のSnapshot復元にもショートカットを割り当て可能。
- メニューバーに常駐。メインウィンドウを閉じてもショートカットを利用可能。

半分・¼などの配置はアクセシビリティAPIでウィンドウの座標を設定します。macOSの「移動とサイズ変更」メニューを直接実行する方式ではないため、OSのタイル余白設定やSplit Viewの管理には連動しません。最小化とフルスクリーン切替はネイティブのウィンドウ属性を操作します。

## ビルド・起動

必要環境：macOS 14以降、Swift 6以降のXcodeまたはCommand Line Tools。

```sh
./scripts/build-app.sh
open "dist/Window Arrange.app"
```

デバッグ版は `./scripts/build-app.sh debug`。SwiftPMの追加サンドボックスを起動できないビルド環境では、`WINDOW_ARRANGE_NESTED_SANDBOX=1 ./scripts/build-app.sh` を使います。

生成されるアプリはローカル実行向けのad-hoc署名です。ほかのMacへの配布ではDeveloper ID署名と公証を別途設定してください。開発中の再ビルドでコード署名が変わると、アクセシビリティ権限の再登録が必要になることがあります。

## 使い方

1. 起動後「設定を開く」から、システム設定 → プライバシーとセキュリティ → アクセシビリティでWindow Arrangeを許可します。
2. アプリのウィンドウを好きな場所・大きさ・Spaceに配置します。
3. 「Snapshotを保存」を押します。名前変更・削除はSnapshotの右クリックメニューから行えます。
4. 配置を変更し、保存したSnapshotを選択して「復元」を押します。
5. 「ショートカット」でキーを設定すると、対象アプリを前面にしたまま操作できます。⌘または⌃を含む組み合わせを入力してください。

Spacesの所属を記録しない場合は「設定」のトグルをオフにします。設定は新規Snapshotに適用され、既存Snapshotは保存時の方式で復元します。起動時にはショートカットが未設定です。macOSや他アプリと競合する組み合わせは登録エラーを表示します。キーは物理キーコードで記録するため、キーボード配列変更後は表示と実際のキーが異なる場合があります。

## Spacesの対応範囲

Spaces連携には公開APIがないため、`NativeSpaces.swift` だけに非公開APIを隔離しています。外部のヘルパーアプリ、デーモン、Dockへの注入、SIP設定変更は行いません。

- `dlopen` / `dlsym` でSkyLightとApplicationServicesのシンボルを取得します。
- 通常のSpaceをUUIDで保存し、復元時に現在のUUIDと照合します。デスクトップ番号を固定IDとして扱いません。
- 新しいOSのbridged window management operationを優先し、存在しない環境では従来のSpace移動APIを使用します。
- Space移動の結果を最大2秒待って照合し、拒否や未対応を復元結果に表示します。シンボルの検出は実際の移動成功を保証しません。
- 削除したSpaceの再作成、Spaceそのものの並べ替え、Spaceのモニター間移動は対象外です。
- フルスクリーン／Split View、すべてのデスクトップに表示するウィンドウ、所属が取得できないウィンドウはSnapshotの対象外です。
- アプリによっては非アクティブなSpaceのウィンドウがアクセシビリティAPIに現れません。保存前に対象Spaceを一度ずつ表示してください。APIに列挙されないウィンドウの完全性は保証できません。
- macOSの更新で非公開APIの構造・動作が変わる可能性があります。Mac App Store向けには、この機能を除いた構成にする必要があります。

## 復元のルール

ウィンドウの照合は、同一プロセス起動中のウィンドウID、アプリ内で一意のアクセシビリティ識別子、一意の書類URL、一意のタイトルの順です。Macやアプリの再起動後には、古いウィンドウIDを使いません。

VS Code / VS Code Insidersでは、標準のmacOSタイトル形式からプロジェクト名・プロファイル名も照合します。開いているファイルが変わった場合や、保存時の `sample-project — Work` が再起動後に `Welcome — sample-project — Work` となった場合も、既存Snapshotのタイトルから照合できます。Snapshotの作り直しは不要です。独自のタイトル形式・区切り文字への変更や、同じプロジェクト・プロファイルの複数ウィンドウは特定できない場合があります。

候補の一意性は、照合済みのものも含めた全ウィンドウで確認します。列挙順や現在の位置で割り当てを推測しません。保存側・現在側ともそのアプリのウィンドウが1件なら単一ウィンドウとして照合し、複数ウィンドウが曖昧な場合はスキップします。

閉じたアプリ・書類・ブラウザータブは開き直しません。前後関係、アプリの非表示状態、Stage Managerのグループ、フォーカスは記録しません。アプリが独自に設定している「特定のデスクトップに割り当てる」設定の変更にも対応しません。

モニターや作業領域が同じなら保存座標をそのまま使い、解像度・Dock配置・接続モニターが変わった場合は利用可能な領域に合わせて調整します。Spacesを含むSnapshotでは、保存先Spaceが存在しないウィンドウは移動せず結果に表示します。アプリ独自の最小サイズなどで要求した配置にならない場合も、成功件数に含めません。

## 保存データ

`~/Library/Application Support/WindowArrange/state.json` にJSONをatomic writeで保存します。ウィンドウタイトルと、取得可能な場合は書類URLを含むため、書類名やファイルパスが保存データに含まれます。画像・書類内容・通信・クラウド保存はありません。書類URLを持たない以前のSnapshotも引き続き読み込めます。

既存ファイルが壊れている場合は上書きを止め、パスとエラーを表示します。ファイルを退避・修復してから再起動してください。

## 検証

```sh
./scripts/test.sh
"dist/Window Arrange.app/Contents/MacOS/WindowArrange" --diagnostics
"dist/Window Arrange.app/Contents/MacOS/WindowArrange" --restore-diagnostics
```

Swift Testingで座標変換、モニター選択、ウィンドウ照合、JSONの保存・読み込み、破損データ、キー競合判定を確認します。`--diagnostics` は権限やSpaceシンボルの検出状況を読み取り、ウィンドウ操作や保存はしません。

`--restore-diagnostics` は、既存Snapshotと現在のウィンドウを照合し、アプリごとの保存数・現在数・照合数と、見つからないSpaceの数を表示します。ウィンドウの移動・設定保存は行いません。

デバッグ版には、自分自身が生成する使い捨てのウィンドウだけを操作する統合チェックも含めています。実行にはアクセシビリティ権限と、Spaces間の検証用に既存の通常デスクトップ2つが必要です。権限は自動的に付与しません。

```sh
./scripts/build-app.sh debug
"dist/Window Arrange.app/Contents/MacOS/WindowArrange" --integration-check
```

この開発環境での確認結果：自動テスト35件成功。Mac再起動後の実際の既存Snapshotに対し、VS Codeの2ウィンドウが両方照合されることを読み取り専用の診断で確認しました。検証ウィンドウの移動・サイズ変更、元の座標への復元、最小化と解除、別Spaceへの移動、元のSpaceと座標への復元も確認済みです。画面上ではキーの記録・解除と重複エラー表示も確認しました。ほかのOSバージョン・各アプリでのSpaces対応は別途確認が必要です。

実機では、異なるアプリでのショートカット、同一アプリの複数ウィンドウ、異なるSpacesへの移動、モニター着脱、サイズ制約のあるアプリ、削除されたSpaceについて確認してください。

## 構成

| 場所 | 役割 |
| --- | --- |
| `Sources/ArrangementCore` | 保存モデル、座標計算、ウィンドウ照合、JSONストレージ |
| `Sources/WindowArrange/AccessibilityService.swift` | 通常ウィンドウの列挙・移動・サイズ変更 |
| `Sources/WindowArrange/NativeSpaces.swift` | 実験的Spaces APIアダプター |
| `Sources/WindowArrange/HotKeyManager.swift` | Carbonホットキー、キー入力UI |
| `Sources/WindowArrange/AppModel.swift` | 保存・復元・設定・結果表示 |
| `Sources/WindowArrange/ContentView.swift` | SwiftUI画面 |

仕様確認に使った一次資料：

- [Apple: AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
- [Apple: AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [Apple: NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)
- [yabaiのSpaces操作実装](https://github.com/asmvik/yabai/blob/master/src/space_manager.c)（非公開APIのシグネチャと方式の参考。コードやアプリへの依存はありません）
