# 統合ブランチの確認事項

このブランチは、shimaさんが作成しているオフライン地図アプリを土台にしています。相手側の `main` は変更していません。

## 取り込んだ機能・ファイル

- Firebase Authentication、アカウント引き継ぎ、友達・救助要請機能
- PMTilesを使う沖縄オフライン地図、日本語フォント、地図用タイル資産
- 管理者一覧から対象者のオフライン地図を開く機能
- 管理者画面の「電池20%以下」絞り込み
- `accountRoles` の既存ゲスト申請と、承認済み管理者ロール
- Firestoreの `users`、`user_access`、中継データ用ルール

## Firebaseについて

統合アプリは `yambaru-last-signal-2` を使用する設定に変更しました。Androidパッケージ `com.example.my_app` を元プロジェクトへFirebaseアプリとして登録し、Webは元プロジェクトの既存Firebaseアプリ設定を使います。`disaster-location-app` のFirestoreデータやAuthアカウントは変更・削除していません。

統合アプリのFirestoreルールは、元プロジェクト側の `firestore.rules` に揃えています。ルールを元プロジェクトへデプロイしてはいません。元プロジェクトで既に適用されているルールがアプリのアクセスを許可することを確認してから、必要であれば別途デプロイしてください。

## データ移行状況

アプリは元プロジェクトの既存FirestoreとAuthenticationを直接使用します。そのためFirestoreデータのコピーは不要です。`disaster-location-app` に作成したFirestoreルールは残っていますが、現在のアプリ設定では使用しません。
