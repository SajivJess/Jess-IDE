import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';
import '../../services/auth_api_service.dart';

class SettingsScreen extends StatefulWidget {
  final VoidCallback? onSignOut;

  const SettingsScreen({
    super.key,
    this.onSignOut,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _urlController = TextEditingController();
  bool _isTesting = false;
  String? _testStatus;
  bool _testSuccess = false;

  @override
  void initState() {
    super.initState();
    _urlController.text = AuthApiService.baseUrl;
    _urlController.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    super.dispose();
  }

  void _onUrlChanged() {
    setState(() {});
  }

  Widget _buildSecurityNotice() {
    final url = _urlController.text.trim().toLowerCase();
    if (url.isEmpty) return const SizedBox.shrink();

    if (url.startsWith('https://')) {
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, size: 14, color: AppColors.statusSuccess),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Encrypted HTTPS connection active.',
                style: AppTypography.codeSm.copyWith(color: AppColors.statusSuccess, fontSize: 11),
              ),
            ),
          ],
        ),
      );
    } else if (url.startsWith('http://')) {
      final isLocal = url.contains('127.0.0.1') || url.contains('localhost') || url.contains('10.0.2.2');
      if (isLocal) {
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Row(
            children: [
              const Icon(Icons.developer_mode, size: 14, color: AppColors.lavender),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Local Development: Allowed by Android network security config (USB ADB/Emulator).',
                  style: AppTypography.codeSm.copyWith(color: AppColors.lavender, fontSize: 11),
                ),
              ),
            ],
          ),
        );
      } else {
        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: Colors.amber.withOpacity(0.4)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.amberAccent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Insecure HTTP Connection: Bearer tokens and task payloads are unencrypted over the network. Android blocks non-local cleartext by default. Use HTTPS for public or shared networks.',
                    style: AppTypography.codeSm.copyWith(color: Colors.amberAccent, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }
    return const SizedBox.shrink();
  }

  Future<void> _testConnection() async {
    setState(() {
      _isTesting = true;
      _testStatus = 'Connecting...';
    });

    final stopwatch = Stopwatch()..start();
    try {
      final base = _urlController.text.trim().replaceAll('/api/v1', '');
      final healthUri = Uri.parse('$base/health');
      final res = await http.get(healthUri).timeout(const Duration(seconds: 4));
      stopwatch.stop();

      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        setState(() {
          _isTesting = false;
          _testSuccess = true;
          _testStatus = 'HTTP 200 OK (${stopwatch.elapsedMilliseconds}ms) · status: ${data['status'] ?? 'healthy'}';
          AuthApiService.baseUrl = _urlController.text.trim();
        });
      } else {
        setState(() {
          _isTesting = false;
          _testSuccess = false;
          _testStatus = 'HTTP ${res.statusCode}: ${res.body}';
        });
      }
    } catch (e) {
      stopwatch.stop();
      setState(() {
        _isTesting = false;
        _testSuccess = false;
        _testStatus = 'Connection failed: $e';
      });
    }
  }

  void _applyPreset(String url) {
    setState(() {
      _urlController.text = url;
      AuthApiService.baseUrl = url;
    });
    _testConnection();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        title: 'Settings',
        showBack: Navigator.of(context).canPop(),
        onBackPressed: () => Navigator.of(context).maybePop(),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Section: Backend Host
                Text('Backend Host Configuration', style: AppTypography.headlineSm),
                const SizedBox(height: 4),
                Text(
                  'Route requests to your local USB debug bridge or Wi-Fi LAN host.',
                  style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),

                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceMain,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Preset Buttons
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _buildPresetChip(
                            label: 'USB ADB (127.0.0.1:8000)',
                            url: 'http://127.0.0.1:8000/api/v1',
                          ),
                          _buildPresetChip(
                            label: 'Android Emulator (10.0.2.2:8000)',
                            url: 'http://10.0.2.2:8000/api/v1',
                          ),
                          _buildPresetChip(
                            label: 'LAN Host (192.168.1.100:8000)',
                            url: 'http://192.168.1.100:8000/api/v1',
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),

                      TextField(
                        controller: _urlController,
                        style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          labelText: 'API Base URL',
                          labelStyle: AppTypography.labelSm.copyWith(color: AppColors.textSecondary),
                          filled: true,
                          fillColor: AppColors.surfaceElevated,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: const BorderSide(color: AppColors.borderSubtle),
                          ),
                        ),
                      ),
                      _buildSecurityNotice(),
                      const SizedBox(height: 10),

                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          ElevatedButton.icon(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.surfaceElevated,
                              foregroundColor: AppColors.textPrimary,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6),
                                side: const BorderSide(color: AppColors.borderSubtle),
                              ),
                            ),
                            icon: _isTesting
                                ? const SizedBox(
                                    width: 14,
                                    height: 14,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.primary),
                                  )
                                : const Icon(Icons.bolt, size: 16, color: AppColors.lavender),
                            label: const Text('Ping / Test Probe'),
                            onPressed: _isTesting ? null : _testConnection,
                          ),
                          if (_testStatus != null)
                            StatusBadge(
                              label: _testSuccess ? 'CONNECTED' : 'FAILED',
                              type: _testSuccess ? StatusType.success : StatusType.error,
                            ),
                        ],
                      ),
                      if (_testStatus != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          _testStatus!,
                          style: AppTypography.codeSm.copyWith(
                            color: _testSuccess ? AppColors.statusSuccess : AppColors.statusError,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Section: Runtime Environment
                Text('Developer Environment', style: AppTypography.headlineSm),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceMain,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Column(
                    children: [
                      _buildInfoRow(Icons.dns_outlined, 'Docker Workspaces', 'Phase 6 Ready'),
                      const Divider(color: AppColors.borderSubtle, height: 16),
                      _buildInfoRow(Icons.adb, 'Android Device', '2311DRK48I (API 36)'),
                      const Divider(color: AppColors.borderSubtle, height: 16),
                      _buildInfoRow(Icons.swap_calls, 'Port Forwarding', 'tcp:8000 -> tcp:8000'),
                      const Divider(color: AppColors.borderSubtle, height: 16),
                      _buildInfoRow(Icons.security, 'Authentication', 'JWT Bearer Access Token'),
                    ],
                  ),
                ),
                const SizedBox(height: 20),

                // Section: Session & Sign Out
                Text('Developer Session', style: AppTypography.headlineSm),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceMain,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: AppColors.borderSubtle),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Row(
                        children: [
                          CircleAvatar(
                            radius: 16,
                            backgroundColor: AppColors.secondaryContainer,
                            child: Text(
                              'DEV',
                              style: AppTypography.codeSm.copyWith(color: AppColors.lavender, fontSize: 10),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Developer Account', style: AppTypography.labelMd),
                              Text('dev@jess.dev', style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11)),
                            ],
                          ),
                        ],
                      ),
                      OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppColors.statusError,
                          side: const BorderSide(color: AppColors.statusError),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                        ),
                        icon: const Icon(Icons.logout, size: 14),
                        label: const Text('Sign Out'),
                        onPressed: widget.onSignOut,
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    'MuseFlow · AI engineering. Beyond your desk.',
                    style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 10),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPresetChip({required String label, required String url}) {
    final isSelected = _urlController.text.trim() == url;
    return InkWell(
      onTap: () => _applyPreset(url),
      borderRadius: BorderRadius.circular(6),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: isSelected ? AppColors.surfaceElevated : AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: isSelected ? AppColors.primary : AppColors.borderSubtle),
        ),
        child: Text(
          label,
          style: AppTypography.codeSm.copyWith(
            color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
            fontSize: 10,
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(IconData icon, String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: AppColors.lavender),
            const SizedBox(width: 8),
            Text(label, style: AppTypography.bodySm),
          ],
        ),
        Text(value, style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary, fontSize: 11)),
      ],
    );
  }
}
