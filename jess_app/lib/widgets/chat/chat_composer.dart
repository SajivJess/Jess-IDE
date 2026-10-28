import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../services/voice_transcribe_service.dart';

class ChatComposer extends StatefulWidget {
  final Function(String text) onSend;
  final VoidCallback onStop;
  final VoidCallback? onAttach;
  final TextEditingController? controller;
  final bool isRunning;
  final bool isApprovalPending;
  final String statusText;
  final bool isConnected;
  final Future<String?> Function()? onVoiceTranscribeOverride;

  const ChatComposer({
    super.key,
    required this.onSend,
    required this.onStop,
    this.onAttach,
    this.controller,
    this.isRunning = false,
    this.isApprovalPending = false,
    this.statusText = 'Ready',
    this.isConnected = true,
    this.onVoiceTranscribeOverride,
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  late final TextEditingController _internalController;
  TextEditingController get _controller => widget.controller ?? _internalController;
  bool _canSend = false;

  late final VoiceTranscribeService _voiceService;
  bool _isVoiceRecording = false;
  bool _isVoiceTranscribing = false;

  @override
  void initState() {
    super.initState();
    _internalController = TextEditingController();
    _voiceService = VoiceTranscribeService();
    _controller.addListener(_onTextChanged);
    _canSend = _controller.text.trim().isNotEmpty;
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText != _canSend && mounted) {
      setState(() => _canSend = hasText);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _internalController.dispose();
    _voiceService.dispose();
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    widget.onSend(text);
  }

  Future<void> _handleVoiceTap() async {
    // If an override is provided (e.g. for headless widget tests or simulations)
    if (widget.onVoiceTranscribeOverride != null) {
      setState(() => _isVoiceTranscribing = true);
      try {
        final text = await widget.onVoiceTranscribeOverride!();
        if (mounted && text != null && text.trim().isNotEmpty) {
          _applyTranscribedText(text.trim());
        }
      } finally {
        if (mounted) setState(() => _isVoiceTranscribing = false);
      }
      return;
    }

    if (_isVoiceTranscribing) return;

    if (!_isVoiceRecording) {
      // Start recording
      final started = await _voiceService.startRecording();
      if (!mounted) return;
      if (started) {
        setState(() => _isVoiceRecording = true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Microphone permission required for voice transcription.'),
            backgroundColor: AppColors.statusError,
            duration: Duration(seconds: 3),
          ),
        );
      }
    } else {
      // Stop recording and transcribe
      setState(() {
        _isVoiceRecording = false;
        _isVoiceTranscribing = true;
      });

      final transcript = await _voiceService.stopRecordingAndTranscribe();
      if (!mounted) return;

      setState(() => _isVoiceTranscribing = false);

      if (transcript != null && transcript.trim().isNotEmpty) {
        _applyTranscribedText(transcript.trim());
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not transcribe audio. Please try again or type your message.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _applyTranscribedText(String transcript) {
    final current = _controller.text.trim();
    if (current.isNotEmpty) {
      _controller.text = '$current $transcript';
    } else {
      _controller.text = transcript;
    }
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Speech transcribed! Review or edit before sending.'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  Future<void> _cancelVoiceRecording() async {
    await _voiceService.cancelRecording();
    if (mounted) {
      setState(() {
        _isVoiceRecording = false;
        _isVoiceTranscribing = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isActuallyRunning = widget.isRunning && !widget.isApprovalPending;

    Color statusDotColor;
    if (widget.isApprovalPending) {
      statusDotColor = AppColors.statusWarning;
    } else if (isActuallyRunning) {
      statusDotColor = AppColors.primary;
    } else if (widget.isConnected) {
      statusDotColor = AppColors.statusSuccess;
    } else {
      statusDotColor = AppColors.statusWarning;
    }

    String hintText;
    if (widget.isApprovalPending) {
      hintText = 'Agent is paused — review changes above, or add a note...';
    } else if (isActuallyRunning) {
      hintText = 'Agent is working... (tap stop to interrupt)';
    } else if (_isVoiceRecording) {
      hintText = 'Listening to voice input...';
    } else if (_isVoiceTranscribing) {
      hintText = 'Transcribing with Muse Voice...';
    } else {
      hintText = 'Describe what to inspect, edit, or test...';
    }

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surfaceMain,
        border: Border(top: BorderSide(color: AppColors.borderSubtle)),
      ),
      padding: EdgeInsets.only(
        left: 12,
        right: 12,
        top: 8,
        bottom: MediaQuery.of(context).viewInsets.bottom + 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Run / Connection / Review / Voice Status Line
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusDotColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      widget.statusText,
                      style: AppTypography.codeSm.copyWith(
                        color: widget.isApprovalPending ? AppColors.statusWarning : AppColors.textSecondary,
                        fontSize: 10,
                        fontWeight: widget.isApprovalPending ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ],
                ),
                if (isActuallyRunning)
                  GestureDetector(
                    onTap: widget.onStop,
                    child: Row(
                      children: [
                        const Icon(Icons.stop_circle_outlined, size: 12, color: AppColors.statusError),
                        const SizedBox(width: 4),
                        Text(
                          'Stop Agent',
                          style: AppTypography.codeSm.copyWith(
                            color: AppColors.statusError,
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                else if (widget.isApprovalPending)
                  Row(
                    children: [
                      const Icon(Icons.pause_circle_outline, size: 12, color: AppColors.statusWarning),
                      const SizedBox(width: 4),
                      Text(
                        'Paused for review',
                        style: AppTypography.codeSm.copyWith(
                          color: AppColors.statusWarning,
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),

          // Active Voice Recording / Transcribing Banner
          if (_isVoiceRecording)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.statusError.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.statusError.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      color: AppColors.statusError,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Listening... Tap mic or stop to transcribe with Muse Voice',
                      style: AppTypography.codeSm.copyWith(
                        color: AppColors.statusError,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _cancelVoiceRecording,
                    child: const Icon(Icons.close, size: 14, color: AppColors.textSecondary),
                  ),
                ],
              ),
            )
          else if (_isVoiceTranscribing)
            Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFBD93F9).withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: const Color(0xFFBD93F9).withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFBD93F9)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Transcribing speech (Muse Voice Transcribe 1.0)...',
                      style: AppTypography.codeSm.copyWith(
                        color: const Color(0xFFBD93F9),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Composer Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Attachment icon
              IconButton(
                icon: const Icon(Icons.attach_file, color: AppColors.textSecondary, size: 20),
                onPressed: widget.onAttach ??
                    () {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Attach project file or snippet')),
                      );
                    },
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 4),

              // Text Field
              Expanded(
                child: Container(
                  constraints: const BoxConstraints(maxHeight: 120),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppColors.surfaceElevated,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _isVoiceRecording
                          ? AppColors.statusError.withValues(alpha: 0.5)
                          : (widget.isApprovalPending
                              ? AppColors.statusWarning.withValues(alpha: 0.3)
                              : AppColors.borderSubtle),
                    ),
                  ),
                  child: TextField(
                    controller: _controller,
                    minLines: 1,
                    maxLines: 5,
                    style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      hintText: hintText,
                      hintStyle: AppTypography.bodySm.copyWith(color: AppColors.textMuted),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Microphone button (Muse Voice Transcribe)
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _isVoiceRecording
                      ? AppColors.statusError
                      : (_isVoiceTranscribing
                          ? const Color(0xFFBD93F9).withValues(alpha: 0.2)
                          : AppColors.surfaceBright),
                  borderRadius: BorderRadius.circular(18),
                  border: _isVoiceRecording
                      ? Border.all(color: Colors.white, width: 1.5)
                      : null,
                ),
                child: IconButton(
                  tooltip: _isVoiceRecording ? 'Stop & Transcribe' : 'Voice Input (Muse Voice)',
                  icon: _isVoiceTranscribing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFFBD93F9)),
                          ),
                        )
                      : Icon(
                          _isVoiceRecording ? Icons.stop : Icons.mic,
                          size: 18,
                          color: _isVoiceRecording ? Colors.white : AppColors.textPrimary,
                        ),
                  padding: EdgeInsets.zero,
                  onPressed: _handleVoiceTap,
                ),
              ),
              const SizedBox(width: 6),

              // Action button (Stop while running, Send otherwise)
              if (isActuallyRunning)
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: AppColors.statusError.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(color: AppColors.statusError),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.stop, size: 18, color: AppColors.statusError),
                    padding: EdgeInsets.zero,
                    onPressed: widget.onStop,
                  ),
                )
              else
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: _canSend ? AppColors.primary : AppColors.surfaceBright,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: IconButton(
                    icon: const Icon(Icons.arrow_upward, size: 18, color: Colors.white),
                    padding: EdgeInsets.zero,
                    onPressed: _canSend ? _submit : null,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
