import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

class AppTextField extends StatefulWidget {
  final String? label;
  final Widget? labelTrailing;
  final String? hintText;
  final TextEditingController? controller;
  final String? initialValue;
  final bool isPassword;
  final IconData? prefixIcon;
  final Widget? suffixIcon;
  final String? helperText;
  final String? errorText;
  final TextInputType keyboardType;
  final int maxLines;
  final int? minLines;
  final ValueChanged<String>? onChanged;
  final bool enabled;

  const AppTextField({
    super.key,
    this.label,
    this.labelTrailing,
    this.hintText,
    this.controller,
    this.initialValue,
    this.isPassword = false,
    this.prefixIcon,
    this.suffixIcon,
    this.helperText,
    this.errorText,
    this.keyboardType = TextInputType.text,
    this.maxLines = 1,
    this.minLines,
    this.onChanged,
    this.enabled = true,
  });

  @override
  State<AppTextField> createState() => _AppTextFieldState();
}

class _AppTextFieldState extends State<AppTextField> {
  late bool _obscureText;

  @override
  void initState() {
    super.initState();
    _obscureText = widget.isPassword;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.label != null || widget.labelTrailing != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 6.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                if (widget.label != null)
                  Expanded(
                    child: Text(
                      widget.label!,
                      style: AppTypography.labelMd.copyWith(
                        color: AppColors.textPrimary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                if (widget.labelTrailing != null) ...[
                  const SizedBox(width: 8),
                  widget.labelTrailing!,
                ],
              ],
            ),
          ),
        Container(
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(8.0),
            border: Border.all(
              color: widget.errorText != null
                  ? AppColors.statusError
                  : AppColors.borderSubtle,
              width: 1.0,
            ),
          ),
          child: Row(
            crossAxisAlignment: widget.maxLines > 1
                ? CrossAxisAlignment.start
                : CrossAxisAlignment.center,
            children: [
              if (widget.prefixIcon != null)
                Padding(
                  padding: EdgeInsets.only(
                    left: 12.0,
                    right: 8.0,
                    top: widget.maxLines > 1 ? 12.0 : 0.0,
                  ),
                  child: Icon(
                    widget.prefixIcon,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                ),
              Expanded(
                child: TextFormField(
                  controller: widget.controller,
                  initialValue: widget.initialValue,
                  obscureText: _obscureText,
                  keyboardType: widget.keyboardType,
                  maxLines: widget.isPassword ? 1 : widget.maxLines,
                  minLines: widget.minLines,
                  enabled: widget.enabled,
                  onChanged: widget.onChanged,
                  style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                  cursorColor: AppColors.primary,
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    hintStyle: AppTypography.bodyMd.copyWith(
                      color: AppColors.textSecondary.withOpacity(0.6),
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: widget.prefixIcon == null ? 12.0 : 4.0,
                      vertical: widget.maxLines > 1 ? 12.0 : 12.0,
                    ),
                    border: InputBorder.none,
                    isDense: true,
                  ),
                ),
              ),
              if (widget.isPassword)
                IconButton(
                  icon: Icon(
                    _obscureText ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                  onPressed: () {
                    setState(() {
                      _obscureText = !_obscureText;
                    });
                  },
                )
              else if (widget.suffixIcon != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8.0),
                  child: widget.suffixIcon!,
                ),
            ],
          ),
        ),
        if (widget.errorText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4.0, left: 2.0),
            child: Text(
              widget.errorText!,
              style: AppTypography.bodySm.copyWith(color: AppColors.statusError),
            ),
          )
        else if (widget.helperText != null)
          Padding(
            padding: const EdgeInsets.only(top: 4.0, left: 2.0),
            child: Text(
              widget.helperText!,
              style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary),
            ),
          ),
      ],
    );
  }
}
