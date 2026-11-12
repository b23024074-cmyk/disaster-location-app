# 統合ブランチの確認事項

このブランチは、shimaさんが作成しているオフライン地図アプリを土台にしています。相手側の `main` は変更していません。

## 取り込んだ機能・ファイル

- Firebase Authentication、アカウント引き継ぎ、友達・救助要請機能
- PMTilesを使う沖縄オフライン地図、日本語フォント、地図用タイル資産
- 管理者一覧から対象者のオフライン地図を開く機能
- 管理者画面の「電池20%以下」絞り込み
- 現在のアプリで使っているFirestoreルール

## Firebaseについて

このブランチでは、相手側リポジトリの `lib/firebase_options.dart`、`android/app/google-services.json`、Firebaseプロジェクト設定を維持しています。したがって、アプリコードを入れただけでは、現在の `yambaru-last-signal-2` のFirestoreデータは移行されません。

アプリを動かす前に、対象FirebaseプロジェクトでAuthenticationの匿名認証・メール/パスワード認証を有効にし、Firestoreルールと `users`、`user_access`、`admins`、`relay_latest`、`relay_history` のデータ構造を確認してください。既存ユーザーのFirebase UIDとアプリ内ユーザーIDの対応を移行せずにルールだけ適用すると、位置や安否情報を読み書きできない場合があります。

Firestoreルールのデプロイやユーザーデータのコピーは、このブランチ作成では実行していません。
