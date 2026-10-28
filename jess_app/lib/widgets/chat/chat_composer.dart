import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

class ChatComposer extends StatefulWidget {
  final Function(String text) onSend;
  final VoidCallback onStop;
  final VoidCallback? onAttach;
  final TextEditingController? controller;
  final bool isRunning;
  final bool isApprovalPending;
  final String statusText;
  final bool isConnected;

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
  });

  @override
  State<ChatComposer> createState() => _ChatComposerState();
}

class _ChatComposerState extends State<ChatComposer> {
  late final TextEditingController _internalController;
  TextEditingController get _controller => widget.controller ?? _internalController;
  bool _canSend = false;

  @override
  void initState() {
    super.initState();
    _internalController = TextEditingController();
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
    super.dispose();
  }

  void _submit() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    _controller.clear();
    widget.onSend(text);
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
          // Run / Connection / Review Status Line
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
                      color: widget.isApprovalPending
                          ? AppColors.statusWarning.withValues(alpha: 0.3)
                          : AppColors.borderSubtle,
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
              const SizedBox(width: 8),

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
