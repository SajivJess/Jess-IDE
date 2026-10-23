import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';

class ReferenceFile {
  final String name;
  final String size;
  final String type;
  final bool isUploaded;

  const ReferenceFile({
    required this.name,
    required this.size,
    required this.type,
    this.isUploaded = true,
  });
}

class Screen9Ideation extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onAnalyzeIdea;

  const Screen9Ideation({
    super.key,
    this.onBack,
    this.onAnalyzeIdea,
  });

  @override
  State<Screen9Ideation> createState() => _Screen9IdeationState();
}

class _Screen9IdeationState extends State<Screen9Ideation> {
  final TextEditingController _ideaController = TextEditingController(
    text:
        'Build an event-driven background job orchestration daemon in Go for distributed worker nodes with automatic checkpointing and WebSocket event streams.',
  );

  bool _isListening = false;
  bool _isAnalyzing = false;
  final Set<String> _selectedFocusChips = {'MVP first', 'Offline-first', 'Security'};

  final List<ReferenceFile> _referenceFiles = [
    const ReferenceFile(name: 'architecture_spec.pdf', size: '2.4 MB', type: 'PDF'),
    const ReferenceFile(name: 'api_endpoints.json', size: '42 KB', type: 'JSON'),
    const ReferenceFile(name: 'system_topology_diagram.png', size: '820 KB', type: 'PNG'),
  ];

  final List<String> _availableChips = [
    'MVP first',
    'Offline-first',
    'Low-cost',
    'Accessibility',
    'Security',
    'Scalability',
  ];

  void _handleAnalyze() async {
    setState(() => _isAnalyzing = true);
    await Future.delayed(const Duration(milliseconds: 1000));
    if (mounted) {
      setState(() => _isAnalyzing = false);
      widget.onAnalyzeIdea?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
        title: 'New Project: Ideation',
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              // Wizard Step Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  color: AppColors.surfaceMain,
                  border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Capture Idea & Context', style: AppTypography.labelMd),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Text('Step 2 of 5', style: AppTypography.codeSm.copyWith(color: AppColors.lavender)),
                    ),
                  ],
                ),
              ),

              // Scrollable Content
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Describe your idea', style: AppTypography.headlineLg),
                      const SizedBox(height: 4),
                      Text(
                        'Describe the problem you want to solve. Add reference files to make the technical analysis more accurate.',
                        style: AppTypography.bodyMd,
                      ),
                      const SizedBox(height: 16),

                      // Problem Statement Section
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
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Project idea / problem statement *', style: AppTypography.labelMd),
                                Text('${_ideaController.text.length} / 2,000', style: AppTypography.codeSm.copyWith(fontSize: 11)),
                              ],
                            ),
                            const SizedBox(height: 10),
                            Stack(
                              children: [
                                TextField(
                                  controller: _ideaController,
                                  maxLines: 5,
                                  onChanged: (_) => setState(() {}),
                                  style: AppTypography.bodyMd.copyWith(color: AppColors.textPrimary),
                                  decoration: InputDecoration(
                                    filled: true,
                                    fillColor: AppColors.surfaceElevated,
                                    hintText: 'e.g. Build an event-driven background job orchestration daemon...',
                                    hintStyle: AppTypography.bodySm.copyWith(color: AppColors.textSecondary),
                                    border: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: AppColors.borderSubtle),
                                    ),
                                    focusedBorder: OutlineInputBorder(
                                      borderRadius: BorderRadius.circular(8),
                                      borderSide: const BorderSide(color: AppColors.primary),
                                    ),
                                    contentPadding: const EdgeInsets.fromLTRB(12, 12, 40, 12),
                                  ),
                                ),
                                Positioned(
                                  top: 8,
                                  right: 8,
                                  child: IconButton(
                                    icon: Icon(
                                      _isListening ? Icons.mic : Icons.mic_none,
                                      color: _isListening ? AppColors.statusError : AppColors.lavender,
                                      size: 20,
                                    ),
                                    onPressed: () {
                                      setState(() => _isListening = !_isListening);
                                      if (_isListening) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          const SnackBar(content: Text('Listening... speak now')),
                                        );
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            if (_isListening) ...[
                              const SizedBox(height: 10),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.primary.withOpacity(0.4)),
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
                                    Text('Listening to speech...', style: AppTypography.labelSm.copyWith(color: AppColors.textPrimary)),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Focus Chips Section
                      Text('Help focus the analysis (optional)', style: AppTypography.labelMd),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: _availableChips.map((chip) {
                          final isSelected = _selectedFocusChips.contains(chip);
                          return FilterChip(
                            label: Text(chip),
                            selected: isSelected,
                            onSelected: (selected) {
                              setState(() {
                                if (selected) {
                                  _selectedFocusChips.add(chip);
                                } else {
                                  _selectedFocusChips.remove(chip);
                                }
                              });
                            },
                            backgroundColor: AppColors.surfaceMain,
                            selectedColor: AppColors.primary.withOpacity(0.18),
                            checkmarkColor: AppColors.lavender,
                            labelStyle: AppTypography.labelSm.copyWith(
                              color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                            ),
                            side: BorderSide(
                              color: isSelected ? AppColors.primary : AppColors.borderSubtle,
                            ),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                          );
                        }).toList(),
                      ),
                      const SizedBox(height: 16),

                      // Reference Files Section (up to 10 files)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Text('Reference files', style: AppTypography.labelMd),
                              const SizedBox(width: 6),
                              Text('(${_referenceFiles.length}/10)', style: AppTypography.codeSm.copyWith(fontSize: 11)),
                            ],
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.upload_file, size: 16, color: AppColors.primary),
                            label: Text('Add file', style: AppTypography.labelSm.copyWith(color: AppColors.primary)),
                            onPressed: () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('File picker (PDF, DOCX, TXT, PNG, JSON)')),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),

                      // Uploaded Files List
                      ...List.generate(_referenceFiles.length, (index) {
                        final file = _referenceFiles[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceMain,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppColors.borderSubtle),
                          ),
                          child: Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceElevated,
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: const Icon(Icons.insert_drive_file_outlined, size: 18, color: AppColors.lavender),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(file.name, style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary), overflow: TextOverflow.ellipsis),
                                    Text('${file.size} · ${file.type}', style: AppTypography.codeSm.copyWith(fontSize: 10)),
                                  ],
                                ),
                              ),
                              const StatusBadge(label: 'Uploaded', type: StatusType.success),
                              const SizedBox(width: 6),
                              IconButton(
                                icon: const Icon(Icons.close, size: 16, color: AppColors.textSecondary),
                                onPressed: () {
                                  setState(() => _referenceFiles.removeAt(index));
                                },
                              ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                ),
              ),

              // Bottom Actions
              Container(
                padding: const EdgeInsets.all(16),
                decoration: const BoxDecoration(
                  color: AppColors.surface,
                  border: Border(top: BorderSide(color: AppColors.borderSubtle)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: AppButton(
                        text: 'Back',
                        variant: AppButtonVariant.outline,
                        onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: AppButton(
                        text: 'Analyze Idea',
                        isLoading: _isAnalyzing,
                        icon: const Icon(Icons.auto_awesome, size: 16, color: Colors.white),
                        onPressed: _handleAnalyze,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
