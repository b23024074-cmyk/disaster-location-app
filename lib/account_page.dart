import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

class AccountPage extends StatefulWidget {
  final Future<void> Function()? beforeCurrentAccountLink;
  final Future<void> Function()? beforeExistingAccountSignIn;

  const AccountPage({
    super.key,
    this.beforeCurrentAccountLink,
    this.beforeExistingAccountSignIn,
  });

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _working = false;
  bool _obscurePassword = true;

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _messageFor(FirebaseAuthException error) {
    switch (error.code) {
      case 'email-already-in-use':
      case 'credential-already-in-use':
        return 'このメールアドレスは別のアカウントで使われています。既存アカウントにログインしてください。';
      case 'invalid-email':
        return 'メールアドレスの形式を確認してください。';
      case 'weak-password':
        return 'パスワードは6文字以上にしてください。';
      case 'wrong-password':
      case 'invalid-credential':
        return 'メールアドレスまたはパスワードが違います。';
      case 'user-not-found':
        return 'このメールアドレスのアカウントが見つかりません。';
      case 'network-request-failed':
        return '通信できません。ネットワークを確認してください。';
      case 'too-many-requests':
        return '試行回数が多すぎます。しばらくしてから再度お試しください。';
      default:
        return error.message ?? '認証に失敗しました（${error.code}）';
    }
  }

  Future<void> _linkCurrentAccount() async {
    final user = _user;
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (user == null || !user.isAnonymous) {
      _showMessage('連結できる匿名アカウントがありません。');
      return;
    }
    if (email.isEmpty || password.length < 6) {
      _showMessage('メールアドレスと6文字以上のパスワードを入力してください。');
      return;
    }

    setState(() => _working = true);
    try {
      await widget.beforeCurrentAccountLink?.call();
      final result = await user.linkWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      );
      var verificationSent = true;
      try {
        await result.user?.sendEmailVerification();
      } catch (_) {
        verificationSent = false;
      }
      if (!mounted) return;
      _showMessage(
        verificationSent
            ? '現在のデータを引き継いで登録しました。確認メールを送信しました。'
            : '現在のデータを引き継いで登録しました。確認メールは後で再送してください。',
      );
      Navigator.pop(context, true);
    } on FirebaseAuthException catch (error) {
      _showMessage(_messageFor(error));
    } catch (error) {
      _showMessage('登録できませんでした: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _signIn() async {
    final email = _emailController.text.trim();
    final password = _passwordController.text;
    if (email.isEmpty || password.isEmpty) {
      _showMessage('メールアドレスとパスワードを入力してください。');
      return;
    }

    final current = _user;
    if (current?.isAnonymous == true) {
      final proceed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('既存アカウントにログイン'),
          content: const Text(
            '今の一時アカウントの名前・位置・安否情報をログイン先へ引き継ぎます。'
            'ログイン先に既に情報がある場合、名前などは既存情報を優先し、'
            '位置は取得時刻が新しい方を使います。友達登録は引き継がれません。'
            '\n\n続けますか？',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('キャンセル'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('ログインして引き継ぐ'),
            ),
          ],
        ),
      );
      if (proceed != true) return;
    }

    setState(() => _working = true);
    try {
      if (current?.isAnonymous == true) {
        await widget.beforeExistingAccountSignIn?.call();
      }
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      if (!mounted) return;
      Navigator.pop(context, true);
    } on FirebaseAuthException catch (error) {
      _showMessage(_messageFor(error));
    } catch (error) {
      _showMessage('ログインできませんでした: $error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final anonymous = user?.isAnonymous ?? true;
    return Scaffold(
      appBar: AppBar(title: const Text('アカウント')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: ListTile(
              leading: Icon(
                anonymous ? Icons.person_outline : Icons.verified_user,
              ),
              title: Text(anonymous ? '一時アカウント' : (user?.email ?? '登録済みアカウント')),
              subtitle: SelectableText('Firebase UID: ${user?.uid ?? '未認証'}'),
            ),
          ),
          const SizedBox(height: 18),
          TextField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(
              labelText: 'メールアドレス',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _passwordController,
            obscureText: _obscurePassword,
            autofillHints: const [AutofillHints.newPassword],
            decoration: InputDecoration(
              labelText: 'パスワード（6文字以上）',
              border: const OutlineInputBorder(),
              suffixIcon: IconButton(
                onPressed: () =>
                    setState(() => _obscurePassword = !_obscurePassword),
                icon: Icon(
                  _obscurePassword ? Icons.visibility : Icons.visibility_off,
                ),
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (anonymous) ...[
            FilledButton.icon(
              onPressed: _working ? null : _linkCurrentAccount,
              icon: const Icon(Icons.save_outlined),
              label: const Text('今のデータを引き継いでアカウント登録'),
            ),
            const Padding(
              padding: EdgeInsets.only(top: 8, bottom: 20),
              child: Text('現在の匿名UIDをメール認証に連結するため、Firestore上のユーザーIDと友達情報を保てます。'),
            ),
          ],
          OutlinedButton.icon(
            onPressed: _working ? null : _signIn,
            icon: const Icon(Icons.login),
            label: const Text('既存アカウントにログイン'),
          ),
          if (_working) ...[
            const SizedBox(height: 20),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}
