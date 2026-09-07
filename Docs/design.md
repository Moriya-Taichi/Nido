# Nidoの設計

Nidoの入力は通常のSwiftプログラムです。Swiftコンパイラーが型を検証した後、プログラムの実行で
`Stack`を構築し、参照関係を含む中間表現からTerraform JSONと構成図を出力します。

## 実行エンジンとの境界

Terraform／OpenTofuに実行を委譲することで、既存のプロバイダー、バックエンド、ロック、依存順序、
変更プラン、置換、削除、ドリフト検出、失敗後のstate保存をそのまま利用します。Nidoは独自のstate形式や
プロバイダーRPCの代替実装を持ちません。エンジンは別途インストールします。

参考：[Terraform JSON configuration syntax](https://developer.hashicorp.com/terraform/language/syntax/json)、
[Terraform plan](https://developer.hashicorp.com/terraform/cli/commands/plan)。

## 型の構造

`Value<T>`は値そのものではなく、型付きの式です。リテラル、リソース参照、配列、オブジェクトの各要素に
依存関係とsensitive情報を保持し、シリアライズ時だけ型を消去します。

`NidoAWS`では、リージョン、VPCのスコープ、CPUアーキテクチャをジェネリクスの引数にします。
`EC2Instance<R, N, A>`は`AMI<R, A>`、`Subnet<R, N>`、`SecurityGroup<R, N>`を要求します。
アーキテクチャはAMI検索の実フィルターにも反映されます。

スコープマーカーはSwiftの名目的な型です。実行時に作られるVPCの同一性そのものをコンパイラーが証明するものでは
ありません。同じマーカーを再利用した場合のVPCの取り違えは、インスタンス構築時の追加検証で扱います。
リージョン名、追加したインスタンスタイプ、クラウドの実状態の整合性はvalidate／plan／applyで確認します。

参考：[Swift Generics](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/generics/)、
[AWS AMI data source](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami)。

## クラウド固有の型

`NidoAzure`の`AzureNetworkInterface<R, S, N>`は地域・サブスクリプション・ネットワークを保持します。
`AzureLinuxVirtualMachine<R, S, N, A>`には、そのNICとCPUが一致するサイズ・イメージを渡します。
NSGルールとNICへの関連付けは管理リソースとして生成され、VMの作成前に依存順序で適用されます。

`NidoGoogleCloud`の`GoogleNetwork<P, N>`はプロジェクト単位のグローバルVPCです。
`GoogleSubnetwork<R, P, N>`でリージョンを追加し、`GoogleComputeInstance<R, P, N, A>`は
`GoogleZone<R>`を要求します。ゾーン文字列のリージョン部分は構築時にも確認します。
VMへ渡したFirewallのネットワーク参照を確認し、ターゲットタグと依存関係を自動設定します。

各クラウドに同名の低レベルResourceを統一せず、意味が異なる構成を区別します。
Azure/GCPのイメージ型は同梱の既知のイメージURN/familyに対応します。実際のイメージ検索・在庫確認は
行いません。`unchecked`や独自のRegion/CPU型の妥当性は利用側の責任です。
サイズの地域別提供状況、権限、サービス有効化、SKUの制限、実在するアカウントは実行エンジンとクラウドで検証します。
専用APIは上記の基礎リソースに限定し、マネージドDB・Kubernetes・IAMなどはスキーマ生成APIで拡張します。

仕様確認元：
[AzureRM 4.0.0 Linux VM](https://github.com/hashicorp/terraform-provider-azurerm/blob/v4.0.0/website/docs/r/linux_virtual_machine.html.markdown)、
[Google 6.0.0 Compute Instance](https://github.com/hashicorp/terraform-provider-google/blob/v6.0.0/website/docs/r/compute_instance.html.markdown)、
[Ubuntu Azureイメージ](https://documentation.ubuntu.com/azure/azure-how-to/instances/find-ubuntu-images/)、
[Azure Dpsv5](https://learn.microsoft.com/en-us/azure/virtual-machines/sizes/general-purpose/dpsv5-series)。

## スキーマ生成

`terraform providers schema -json`のformat 1.xを読み、構造的な型と必須属性をSwiftへ変換します。
ネストした属性のobjectとtupleには専用の型を生成します。computed専用属性を初期化引数には含めません。
schemaがdynamicとする値だけは`JSONValue`を使います。

schemaに含まれない列挙値、相互排他、文字列IDの意味、API権限、インスタンスの提供状況は推測しません。
プロバイダースキーマ自体にはプロバイダーの配布バージョンが入らないため、生成時のバージョン制約は明示的に渡します。
ネストしたobject属性のoptionalキー情報が公開されていない場合、そのobjectの全フィールドを必須とする保守的なAPIです。

参考：[Provider schema JSON](https://developer.hashicorp.com/terraform/cli/commands/providers/schema)。

## JSONとグラフ

式を受け取る位置のリテラル文字列は、Terraformのテンプレート開始記号を再帰的にエスケープします。
variableのdefault、provider alias、module source、backend、depends_onなどの特殊な位置には、
TerraformのJSON仕様に従ってリテラルを出力します。

グラフにはアドレス、種類、依存先と、任意の`Architecture`を保存します。以前のJSONも読めます。
設定値は図に流用しません。明示した図のラベル・注釈はそのまま出力するため秘密値を含めないでください。

既定の構成図はサービス・入れ子の境界・明示した通信と同期を描きます。
作成依存関係から通信経路は推測しません。図のリソース参照、親の存在、ID重複、親の循環を検証します。
通信の循環は許可します。`--view dependencies`は従来の作成依存関係図を出力します。
SVGは子のサイズから親を決める行ベースのレイアウトと自己完結した独自アイコンを使います。
Mermaid/DOTも境界・通信を出力しますが、SVGと同じレイアウトやアイコンは保証しません。
`Architecture`はTerraform JSONに含めず、インフラの挙動を変更しません。

## 実行と保存

CLIはシェルの文字列評価を使わず、引数配列でSwiftと実行エンジンを起動します。
Swiftプログラムは新しい一時ディレクトリへ出力し、その成功と出力ファイルを確認してから`.nido`の設定を更新します。
以前の設定が残っていても、コンパイル失敗やexport呼び忘れでエンジンを起動しません。

設定は同じディレクトリの一時ファイルからrenameし、ファイル単位で置き換えます。
生成からエンジン終了までは作業ディレクトリのファイルロックを保持し、同じディレクトリへの別のNido操作を拒否します。
リモートstateのロックは、これとは別に実行エンジンが管理します。
保存済みプランを適用するときは`--skip-synth`を指定し、承認したプランをエンジンへ直接渡します。

## 対応範囲

初期実装は型付きフロントエンドとTerraformの標準運用をつなぐものです。HCLをSwiftの専用APIへ完全に一対一で
写したものではありません。独自関数のDSL、すべてのlifecycle条件、provisioner、provider functions、ephemeral resources、
Terraform Stacksの専用APIは未実装です。追加のTerraform設定や`nido exec`は利用できますが、それらの部分に
Swiftの静的保証は付きません。Windowsには未対応です。
