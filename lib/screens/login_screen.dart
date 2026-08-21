import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../services/user_data_service.dart';
import '../utils/font_utils.dart';
import '../widgets/windows_title_bar.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _serverUrlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isPasswordVisible = false;

  /// 「更换地址」是否展开。默认收起，页面上只有账号和密码。
  bool _showServerUrlField = false;
  bool _isLoading = false;
  bool _isFormValid = false;

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_validateForm);
    _passwordController.addListener(_validateForm);
    _loadSavedCredentials();
  }

  Future<void> _loadSavedCredentials() async {
    final userData = await UserDataService.getAllUserData();
    if (!mounted) return;
    // 只回填用户自己填过的地址；默认地址永不显示，留空即代表使用默认。
    final saved = userData['serverUrl']?.trim() ?? '';
    _serverUrlController.text =
        saved.isEmpty || saved == UserDataService.defaultServerUrl ? '' : saved;
    _showServerUrlField = _serverUrlController.text.isNotEmpty;
    _usernameController.text = userData['username'] ?? '';
    _passwordController.text = userData['password'] ?? '';
    _validateForm();
  }

  void _validateForm() {
    if (!mounted) return;
    final valid = _usernameController.text.trim().isNotEmpty &&
        _passwordController.text.isNotEmpty;
    if (valid != _isFormValid) setState(() => _isFormValid = valid);
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _parseCookies(http.Response response) {
    final setCookieHeader = response.headers['set-cookie'];
    if (setCookieHeader == null) return '';
    return setCookieHeader.split(';').first.trim();
  }

  void _showToast(String message, Color backgroundColor) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: FontUtils.poppins(color: Colors.white, fontSize: 14),
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _handleLogin() async {
    if (_isLoading || !_isFormValid || !_formKey.currentState!.validate())
      return;

    setState(() => _isLoading = true);
    try {
      final entered = _serverUrlController.text.trim();
      final baseUrl = _normalizeServerUrl(
        entered.isEmpty ? UserDataService.defaultServerUrl : entered,
      );
      final response = await http
          .post(
            Uri.parse('$baseUrl/api/login'),
            headers: const {'Content-Type': 'application/json'},
            body: json.encode({
              'username': _usernameController.text.trim(),
              'password': _passwordController.text,
            }),
          )
          .timeout(const Duration(seconds: 30));
      if (!mounted) return;

      if (response.statusCode == 200) {
        await UserDataService.saveUserData(
          serverUrl: baseUrl,
          username: _usernameController.text.trim(),
          password: _passwordController.text,
          cookies: _parseCookies(response),
        );
        await UserDataService.saveIsLocalMode(false);
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const HomeScreen()),
          (route) => false,
        );
        return;
      }

      setState(() => _isLoading = false);
      if (response.statusCode == 401) {
        _showToast('账号或密码错误', const Color(0xFFe74c3c));
      } else if (response.statusCode == 500) {
        _showToast('服务器错误', const Color(0xFFe74c3c));
      } else {
        _showToast('网络异常', const Color(0xFFe74c3c));
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      _showToast('网络异常', const Color(0xFFe74c3c));
    }
  }

  /// 补全协议并去掉末尾斜杠，避免用户只输入域名时请求失败。
  String _normalizeServerUrl(String value) {
    var url = value.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    return url.replaceAll(RegExp(r'/+$'), '');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFFe6f3fb),
              Color(0xFFeaf3f7),
              Color(0xFFf7f7f3),
              Color(0xFFe9ecef),
              Color(0xFFdbe3ea),
              Color(0xFFd3dde6),
            ],
            stops: [0.0, 0.18, 0.38, 0.60, 0.80, 1.0],
          ),
        ),
        child: Column(
          children: [
            if (Platform.isWindows) const WindowsTitleBar(forceBlack: true),
            Expanded(
              child: SafeArea(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 24,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 480),
                      child: _buildLoginForm(),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLoginForm() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'tv',
          style: FontUtils.sourceCodePro(
            fontSize: 42,
            fontWeight: FontWeight.w400,
            color: const Color(0xFF2c3e50),
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 40),
        Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildTextField(
                controller: _usernameController,
                label: '账号',
                hint: '请输入账号',
                icon: Icons.person,
                textInputAction: TextInputAction.next,
                validator: (value) =>
                    value == null || value.trim().isEmpty ? '请输入账号' : null,
              ),
              const SizedBox(height: 20),
              _buildTextField(
                controller: _passwordController,
                label: '密码',
                hint: '请输入密码',
                icon: Icons.lock,
                obscureText: !_isPasswordVisible,
                suffixIcon: IconButton(
                  tooltip: _isPasswordVisible ? '隐藏密码' : '显示密码',
                  icon: Icon(
                    _isPasswordVisible
                        ? Icons.visibility
                        : Icons.visibility_off,
                    color: const Color(0xFF7f8c8d),
                    size: 20,
                  ),
                  onPressed: () =>
                      setState(() => _isPasswordVisible = !_isPasswordVisible),
                ),
                onSubmitted: (_) => _handleLogin(),
                validator: (value) =>
                    value == null || value.isEmpty ? '请输入密码' : null,
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: (_isLoading || !_isFormValid) ? null : _handleLogin,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isFormValid && !_isLoading
                      ? const Color(0xFF2c3e50)
                      : const Color(0xFFbdc3c7),
                  foregroundColor: _isFormValid && !_isLoading
                      ? Colors.white
                      : const Color(0xFF7f8c8d),
                  padding: const EdgeInsets.symmetric(vertical: 18),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  elevation: 0,
                  shadowColor: Colors.transparent,
                ),
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white,
                        ),
                      )
                    : Text(
                        '登录',
                        style: FontUtils.poppins(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 1,
                        ),
                      ),
              ),
              const SizedBox(height: 12),
              // 「更换地址」：不点开不显示输入框；留空即使用内置默认地址。
              Align(
                alignment: Alignment.center,
                child: TextButton(
                  onPressed: () => setState(
                      () => _showServerUrlField = !_showServerUrlField),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF7f8c8d),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  child: Text(
                    _showServerUrlField ? '收起' : '更换地址',
                    style: FontUtils.poppins(fontSize: 13),
                  ),
                ),
              ),
              if (_showServerUrlField) ...[
                const SizedBox(height: 4),
                _buildTextField(
                  controller: _serverUrlController,
                  label: '服务器地址',
                  hint: '留空使用默认地址',
                  icon: Icons.link,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _handleLogin(),
                  // 允许留空：留空就走内置默认地址。
                  validator: (_) => null,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required String? Function(String?) validator,
    bool obscureText = false,
    Widget? suffixIcon,
    TextInputAction? textInputAction,
    TextInputType? keyboardType,
    ValueChanged<String>? onSubmitted,
  }) {
    return TextFormField(
      controller: controller,
      obscureText: obscureText,
      textInputAction: textInputAction,
      keyboardType: keyboardType,
      onFieldSubmitted: onSubmitted,
      validator: validator,
      style: FontUtils.poppins(fontSize: 16, color: const Color(0xFF2c3e50)),
      decoration: InputDecoration(
        labelText: label,
        labelStyle: FontUtils.poppins(
          color: const Color(0xFF7f8c8d),
          fontSize: 14,
        ),
        hintText: hint,
        hintStyle: FontUtils.poppins(
          color: const Color(0xFFbdc3c7),
          fontSize: 16,
        ),
        prefixIcon: Icon(icon, color: const Color(0xFF7f8c8d), size: 20),
        suffixIcon: suffixIcon,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.6),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 20,
          vertical: 18,
        ),
      ),
    );
  }
}
