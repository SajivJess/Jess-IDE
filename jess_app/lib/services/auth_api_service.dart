import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class AuthUser {
  final String id;
  final String email;
  final String? fullName;
  final bool isActive;
  final bool isVerified;
  final bool isSuperuser;

  AuthUser({
    required this.id,
    required this.email,
    this.fullName,
    required this.isActive,
    required this.isVerified,
    required this.isSuperuser,
  });

  factory AuthUser.fromJson(Map<String, dynamic> json) {
    return AuthUser(
      id: json['id'] as String? ?? '',
      email: json['email'] as String? ?? '',
      fullName: json['full_name'] as String?,
      isActive: json['is_active'] as bool? ?? true,
      isVerified: json['is_verified'] as bool? ?? false,
      isSuperuser: json['is_superuser'] as bool? ?? false,
    );
  }
}

class AuthResult {
  final bool success;
  final String message;
  final String? accessToken;
  final String? refreshToken;
  final AuthUser? user;
  final bool verificationRequired;
  final String? verificationToken;

  AuthResult({
    required this.success,
    required this.message,
    this.accessToken,
    this.refreshToken,
    this.user,
    this.verificationRequired = false,
    this.verificationToken,
  });
}

class VerificationStatus {
  final bool isVerified;
  final bool exists;
  final String email;

  VerificationStatus({
    required this.isVerified,
    required this.exists,
    required this.email,
  });
}

class AuthApiService {
  // Base URL configuration:
  // - Public Tunnel (Remote/Chennai): https://household-modeling-studio-carry.trycloudflare.com/api/v1
  // - Local USB/Desktop: http://127.0.0.1:8000/api/v1
  static String baseUrl = 'https://household-modeling-studio-carry.trycloudflare.com/api/v1';

  static String? currentAccessToken;
  static String? currentRefreshToken;
  static AuthUser? currentUser;

  static final http.Client _client = http.Client();

  /// Register a new account with the FastAPI backend
  static Future<AuthResult> register({
    required String email,
    required String password,
    String? fullName,
  }) async {
    try {
      final url = Uri.parse('$baseUrl/auth/register');
      final response = await _client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email.trim(),
              'password': password,
              'full_name': fullName?.trim(),
            }),
          )
          .timeout(const Duration(seconds: 8));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 201) {
        final userData = data['user'] as Map<String, dynamic>;
        final user = AuthUser.fromJson(userData);
        currentUser = user;
        return AuthResult(
          success: true,
          message: data['message'] as String? ?? 'Registration successful.',
          user: user,
          verificationRequired: true,
          verificationToken: data['verification_token'] as String?,
        );
      } else {
        final errorMsg = data['detail'] as String? ?? 'Registration failed.';
        return AuthResult(success: false, message: errorMsg);
      }
    } catch (e) {
      if (kDebugMode) print('AuthApiService.register error: $e');
      return AuthResult(
        success: false,
        message: 'Unable to connect to backend ($baseUrl). Please check server connection.',
      );
    }
  }

  /// Login and acquire access and refresh tokens
  static Future<AuthResult> login({
    required String email,
    required String password,
  }) async {
    try {
      final url = Uri.parse('$baseUrl/auth/login');
      final response = await _client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'email': email.trim(),
              'password': password,
            }),
          )
          .timeout(const Duration(seconds: 8));

      final data = jsonDecode(response.body) as Map<String, dynamic>;

      if (response.statusCode == 200) {
        currentAccessToken = data['access_token'] as String?;
        currentRefreshToken = data['refresh_token'] as String?;

        // Retrieve user profile using new access token
        final profile = await getProfile();

        return AuthResult(
          success: true,
          message: 'Signed in successfully.',
          accessToken: currentAccessToken,
          refreshToken: currentRefreshToken,
          user: profile,
        );
      } else {
        final errorMsg = data['detail'] as String? ?? 'Invalid email or password.';
        return AuthResult(success: false, message: errorMsg);
      }
    } catch (e) {
      if (kDebugMode) print('AuthApiService.login error: $e');
      return AuthResult(
        success: false,
        message: 'Unable to connect to backend ($baseUrl). Please check server connection.',
      );
    }
  }

  /// Fetch authenticated user profile via GET /api/v1/auth/me
  static Future<AuthUser?> getProfile() async {
    if (currentAccessToken == null) return null;
    try {
      final url = Uri.parse('$baseUrl/auth/me');
      final response = await _client.get(
        url,
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $currentAccessToken',
        },
      ).timeout(const Duration(seconds: 6));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        currentUser = AuthUser.fromJson(data);
        return currentUser;
      }
      return null;
    } catch (e) {
      if (kDebugMode) print('AuthApiService.getProfile error: $e');
      return null;
    }
  }

  /// Genuine verification status probe
  static Future<VerificationStatus?> checkVerificationStatus(String email) async {
    try {
      final url = Uri.parse('$baseUrl/auth/verify-status?email=${Uri.encodeComponent(email.trim())}');
      final response = await _client.get(url).timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return VerificationStatus(
          isVerified: data['is_verified'] as bool? ?? false,
          exists: data['exists'] as bool? ?? false,
          email: data['email'] as String? ?? email,
        );
      }
      return null;
    } catch (e) {
      if (kDebugMode) print('AuthApiService.checkVerificationStatus error: $e');
      return null;
    }
  }

  /// Request genuine verification email dispatch
  static Future<bool> resendVerification(String email) async {
    try {
      final url = Uri.parse('$baseUrl/auth/resend-verification');
      final response = await _client
          .post(
            url,
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'email': email.trim()}),
          )
          .timeout(const Duration(seconds: 6));

      return response.statusCode == 200;
    } catch (e) {
      if (kDebugMode) print('AuthApiService.resendVerification error: $e');
      return false;
    }
  }
}
