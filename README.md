# Window Arrange

Swift / SwiftUIで作成したmacOS用ウィンドウ配置アプリです。外部アプリ、プラグイン、Swift Packageの外部依存はありません。

## できること

- グローバルショートカットの割り当て・変更・解除。左右上下の半分、四隅の¼、画面いっぱい、中央、次のモニター、最小化、フルスクリーン切替に対応。
- 左右・上下の配置を繰り返すモードをラジオボタンで選択。Cycle は同じ画面内で1/2・2/3・1/3を切り替え、Cycle Displays は半分のサイズでディスプレイ間を移動します。
- 名前付きSnapshotの保存、プレビュー、名前変更、削除。
- 複数アプリの位置・サイズ・モニター・最小化状態をまとめて記録・復元。
- **Spacesの所属の記録・復元（実験機能）**。macOS内蔵のシステムAPIをSwiftから直接呼び出します。
- Snapshot保存と選択中のSnapshot復元にもショートカットを割り当て可能。
- メニューバーのみに常駐し、Dockや⌘Tabには表示されません。起動時にメインウィンドウは開かず、ウィンドウを閉じてもショートカットを利用可能。

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

1. メニューバーのアイコン →「Window Arrangeを開く」で画面を開きます。初回は画面内の「設定を開く」から、システム設定 → プライバシーとセキュリティ → アクセシビリティでWindow Arrangeを許可します。
2. アプリのウィンドウを好きな場所・大きさ・Spaceに配置します。
3. 「Snapshotを保存」を押します。名前変更・削除はSnapshotの右クリックメニューから行えます。
4. 配置を変更し、保存したSnapshotを選択して「復元」を押します。
5. 「ショートカット」でキーを設定すると、対象アプリを前面にしたまま操作できます。⌘または⌃を含む組み合わせを入力してください。

ショートカット一覧の「変更したショートカットのみ表示」をオンにすると、キーを割り当てた項目だけ表示します。割り当てを解除した項目は対象外になり、チェックを外すと全項目に戻ります。フィルターの選択は次回起動時も維持されます。

終了するには、メニューバーのアイコン →「終了」を選びます。

Spacesの所属を記録しない場合は「設定」のトグルをオフにします。設定は新規Snapshotに適用され、既存Snapshotは保存時の方式で復元します。起動時にはショートカットが未設定です。macOSや他アプリと競合する組み合わせは登録エラーを表示します。キーは物理キーコードで記録するため、キーボード配列変更後は表示と実際のキーが異なる場合があります。

## サイズの繰り返し

「ショートカット」または「設定」で、共通のラジオボタンから選びます。選択は保存され、次回起動時も維持されます。既存の保存データでは None が選択されます。

- **None（デフォルト）**：従来どおり、左右・上下を1/2に配置します。
- **Cycle 1/2, 2/3, and 1/3**：同じ配置ショートカットを押すたび、現在のディスプレイ内で1/2 → 2/3 → 1/3 → 1/2…と切り替えます。
- **Cycle Displays**：サイズは1/2のまま、半画面ずつ巡回します。右半分のコマンドでは「画面Aの右 → 画面Bの左 → 画面Bの右 → 画面Aの左 → …」、左半分では逆方向へ進みます。上下もそれぞれの方向に巡回します。接続中の全ディスプレイが対象で、開いているMacBookの内蔵画面も含みます。1画面の場合は半分の配置を維持します。

対象は左・右・上・下の4操作です。Cycle では左右は幅、上下は高さを切り替え、指定した辺に揃えます。Cycle Displays の画面順は左右の操作では横方向、上下の操作では縦方向の画面配置から決めます。四隅の¼などは従来の動作です。現在の位置・サイズから次の段階を判定するため、Cycle ですでに同じ辺の1/2なら次は2/3になります。手動で別の位置・サイズに変更した場合は1/2から始まります。アプリの最小サイズによって1/3にできない場合は、配置結果にエラーを表示します。

以前の rotation 設定は Cycle Displays に引き継ぎます。Raycast の実機比較で、1/2 → 2/3 → 1/3 のサイズ循環と、内蔵画面・外部画面の左右の半画面を巡る順序を確認しました。

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

別のモニターから復元する場合は、まずウィンドウを保存先モニターの座標へ移動して画面移動の完了を待ち、その後で保存先のSpaceと最終座標を適用します。Spaceを先に指定するとモニターをまたぐ復帰が拒否されるケースに対応しています。モニター・Space・位置・サイズが複数回連続して一致するまで成功扱いにしません。

VS Codeなどが非表示Spaceのウィンドウを`AXWindows`から除外しても、保存時や列挙時の参照を保持して復元対象に残します。参照はWindowServerで同じアプリの起動セッションとウィンドウIDが存在する間だけ保持し、終了・再起動後の古い参照は使いません。

アプリを開き直した直後など参照がない場合は、WindowServer側のウィンドウ情報も照合します。対応するmacOSでは対象のSpaceだけを一時表示してウィンドウ参照を取得し、表示していたデスクトップへ戻してから配置を復元します。この取得中は画面が一時的に切り替わります。Space表示APIが未対応の場合や参照を取得できない場合は理由を表示します。

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

`--restore-diagnostics` は、既存Snapshotと現在のウィンドウを照合し、アプリごとの保存数・現在数・照合数と、見つからないSpaceの数を表示します。WindowServerにだけ現れる非表示Spaceのウィンドウ数と、それを含めた照合数も表示します。Spaceの表示切り替え・ウィンドウの移動・設定保存は行いません。

デバッグ版には、自分自身が生成する使い捨てのウィンドウだけを操作する統合チェックも含めています。実行にはアクセシビリティ権限と、Spaces間の検証用に既存の通常デスクトップ2つが必要です。権限は自動的に付与しません。

```sh
./scripts/build-app.sh debug
"dist/Window Arrange.app/Contents/MacOS/WindowArrange" --integration-check
```

この開発環境での確認結果：自動テスト62件成功。検証ウィンドウで、AXWindowsから対象が消える状態を模擬し、キャッシュで対象を維持する場合と、空のキャッシュからSpaceを一時表示して再取得する場合の両方を確認しました。実際のVS Codeでも、WindowServerには存在するがAXWindowsには現れない1枚を再取得し、既存SnapshotのMacBook側のSpace・位置・サイズへ復元できることを確認済みです。

検証ウィンドウで、外部モニターのデスクトップ2からMacBookへの復元、逆方向の復元、外部モニター内のデスクトップ2→1、最小化と解除も確認済みです。画面上ではキーの記録・解除と重複キーのエラー表示も確認しました。ほかのOSバージョン・各アプリでのSpaces対応は別途確認が必要です。

実機では、異なるアプリでのショートカット、同一アプリの複数ウィンドウ、異なるSpacesへの移動、モニター着脱、サイズ制約のあるアプリ、削除されたSpaceについて確認してください。

## 構成

| 場所 | 役割 |
| --- | --- |
| `Sources/ArrangementCore` | 保存モデル、座標計算、ウィンドウ照合、JSONストレージ |
| `Sources/WindowArrange/AccessibilityService.swift` | 通常ウィンドウの列挙・移動・サイズ変更 |
| `Sources/ArrangementCore/WindowPlacement.swift` | モニター→Space→座標の復元順序と完了判定 |
| `Sources/WindowArrange/AccessibilityPlacementClient.swift` | 復元処理と実際のウィンドウ操作の接続 |
| `Sources/ArrangementCore/WindowReferenceCache.swift` | 非表示Spaceのウィンドウ参照の保持・無効化 |
| `Sources/WindowArrange/SnapshotWindowRestorer.swift` | UIと検証で共有するSnapshotの1ウィンドウ復元 |
| `Sources/WindowArrange/NativeSpaces.swift` | 実験的Spaces APIアダプター |
| `Sources/WindowArrange/HotKeyManager.swift` | Carbonホットキー、キー入力UI |
| `Sources/WindowArrange/AppModel.swift` | 保存・復元・設定・結果表示 |
| `Sources/WindowArrange/ContentView.swift` | SwiftUI画面 |

仕様確認に使った一次資料：

- [Apple: AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue)
- [Apple: AXIsProcessTrustedWithOptions](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [Apple: NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)
- [yabaiのSpaces操作実装](https://github.com/asmvik/yabai/blob/master/src/space_manager.c)（非公開APIのシグネチャと方式の参考。コードやアプリへの依存はありません）
