import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';
import '../../widgets/app_button.dart';
import '../../widgets/app_header.dart';
import '../../widgets/status_badge.dart';

class TechChoice {
  final String category;
  final String selectedOption;
  final String rationale;
  final List<String> availableOptions;
  bool isConfirmed;

  TechChoice({
    required this.category,
    required this.selectedOption,
    required this.rationale,
    required this.availableOptions,
    this.isConfirmed = false,
  });
}

class Screen11TechnologyStack extends StatefulWidget {
  final VoidCallback? onBack;
  final VoidCallback? onConfirmStack;

  const Screen11TechnologyStack({
    super.key,
    this.onBack,
    this.onConfirmStack,
  });

  @override
  State<Screen11TechnologyStack> createState() => _Screen11TechnologyStackState();
}

class _Screen11TechnologyStackState extends State<Screen11TechnologyStack> {
  bool _isConfirming = false;
  bool _isWhyExpanded = true;

  final List<TechChoice> _stackItems = [
    TechChoice(
      category: 'Mobile & Desktop UI',
      selectedOption: 'Flutter + Dart (Android · iOS · Desktop)',
      rationale: 'Single declarative codebase targeting Android first, iOS second, and Desktop third with native performance.',
      availableOptions: ['Flutter + Dart (Android · iOS · Desktop)', 'Native Kotlin / Swift', 'React Native'],
      isConfirmed: true,
    ),
    TechChoice(
      category: 'Backend API Framework',
      selectedOption: 'Python 3.12 + FastAPI',
      rationale: 'High-performance async REST endpoints, native WebSockets, Pydantic validation, and modular orchestration.',
      availableOptions: ['Python 3.12 + FastAPI', 'Node.js + Fastify', 'Go + Gin'],
      isConfirmed: true,
    ),
    TechChoice(
      category: 'Real-Time Task Stream',
      selectedOption: 'WebSockets (Live Stream Relay)',
      rationale: 'Bidirectional low-latency stream for live agent token output, tool logs, and human-in-the-loop approvals.',
      availableOptions: ['WebSockets (Live Stream Relay)', 'Server-Sent Events (SSE)', 'gRPC Stream'],
      isConfirmed: true,
    ),
    TechChoice(
      category: 'Persistent Database & ORM',
      selectedOption: 'PostgreSQL + SQLAlchemy & Alembic',
      rationale: 'Durable relational schema for users, projects, tasks, event logs, and audits with versioned migrations.',
      availableOptions: ['PostgreSQL + SQLAlchemy & Alembic', 'PostgreSQL + Prisma', 'SQLite (Local Dev)'],
      isConfirmed: true,
    ),
    TechChoice(
      category: 'Remote Workspace Runtime',
      selectedOption: 'Linux + Docker Isolated Containers',
      rationale: 'Sandboxed execution environment for Git clone, builds, shell commands, and tests with strict resource bounds.',
      availableOptions: ['Linux + Docker Isolated Containers', 'Host Direct Process', 'Kubernetes Pods (Future)'],
      isConfirmed: true,
    ),
    TechChoice(
      category: 'Coding Agent Integration',
      selectedOption: 'Provider-Agnostic Agent Adapter',
      rationale: 'Replaceable runtime supporting approved APIs and standard protocols without vendor or CLI lock-in.',
      availableOptions: ['Provider-Agnostic Agent Adapter', 'Direct CLI Wrapper', 'Custom Router'],
      isConfirmed: true,
    ),
    TechChoice(
      category: 'Background Tasks & Jobs',
      selectedOption: 'Dedicated Worker (Redis-Ready)',
      rationale: 'Decoupled worker ensuring long-running coding operations never block or degrade the core API server.',
      availableOptions: ['Dedicated Worker (Redis-Ready)', 'FastAPI BackgroundTasks', 'Celery + RabbitMQ'],
      isConfirmed: true,
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppHeader(
        showBack: true,
        onBackPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
        title: 'Technology Stack',
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              // Progress Header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                decoration: const BoxDecoration(
                  color: AppColors.surfaceMain,
                  border: Border(bottom: BorderSide(color: AppColors.borderSubtle)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Select Technologies', style: AppTypography.labelMd),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceElevated,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: AppColors.borderSubtle),
                      ),
                      child: Text('Step 4 of 5', style: AppTypography.codeSm.copyWith(color: AppColors.lavender)),
                    ),
                  ],
                ),
              ),

              // Content Area
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Choose your technology stack', style: AppTypography.headlineLg),
                      const SizedBox(height: 4),
                      Text(
                        'Review the suggested technologies and adjust them to fit your project requirements.',
                        style: AppTypography.bodyMd,
                      ),
                      const SizedBox(height: 16),

                      // Expandable "Why this stack?"
                      Container(
                        decoration: BoxDecoration(
                          color: AppColors.surfaceMain,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: AppColors.borderSubtle),
                        ),
                        child: Column(
                          children: [
                            InkWell(
                              onTap: () => setState(() => _isWhyExpanded = !_isWhyExpanded),
                              child: Padding(
                                padding: const EdgeInsets.all(14),
                                child: Row(
                                  children: [
                                    const Icon(Icons.account_tree_outlined, size: 20, color: AppColors.primary),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Text(
                                        'Why this stack? (AI Architecture Synthesis)',
                                        style: AppTypography.labelMd.copyWith(fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    Icon(
                                      _isWhyExpanded ? Icons.expand_less : Icons.expand_more,
                                      color: AppColors.textSecondary,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            if (_isWhyExpanded) ...[
                              const Divider(color: AppColors.borderSubtle),
                              Padding(
                                padding: const EdgeInsets.all(14),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Based on your problem statement analyzed in Step 3, this stack balances mobile client performance with zero-cost local developer machine execution.',
                                      style: AppTypography.bodySm,
                                    ),
                                    const SizedBox(height: 10),
                                    Wrap(
                                      spacing: 8,
                                      runSpacing: 6,
                                      children: [
                                        _buildMiniPill('Zero-Cost Local Run', AppColors.statusSuccess),
                                        _buildMiniPill('Sub-10ms Streaming', AppColors.statusInfo),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // Stack Selection Items
                      ...List.generate(_stackItems.length, (index) {
                        final item = _stackItems[index];
                        return Container(
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceMain,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: item.isConfirmed ? AppColors.primary.withOpacity(0.5) : AppColors.borderSubtle,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(item.category, style: AppTypography.codeSm.copyWith(color: AppColors.textSecondary, fontSize: 11)),
                                  ),
                                  const SizedBox(width: 8),
                                  StatusBadge(
                                    label: item.isConfirmed ? 'Confirmed' : 'Suggested',
                                    type: item.isConfirmed ? StatusType.success : StatusType.warning,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              // Dropdown selector
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10),
                                decoration: BoxDecoration(
                                  color: AppColors.surfaceElevated,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: AppColors.borderSubtle),
                                ),
                                child: DropdownButtonHideUnderline(
                                  child: DropdownButton<String>(
                                    value: item.selectedOption,
                                    isExpanded: true,
                                    dropdownColor: AppColors.surfaceElevated,
                                    style: AppTypography.labelMd.copyWith(color: AppColors.textPrimary),
                                    items: item.availableOptions.map((opt) {
                                      return DropdownMenuItem<String>(
                                        value: opt,
                                        child: Text(opt),
                                      );
                                    }).toList(),
                                    onChanged: (newVal) {
                                      if (newVal != null) {
                                        setState(() {
                                          _stackItems[index] = TechChoice(
                                            category: item.category,
                                            selectedOption: newVal,
                                            rationale: item.rationale,
                                            availableOptions: item.availableOptions,
                                            isConfirmed: true,
                                          );
                                        });
                                      }
                                    },
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(item.rationale, style: AppTypography.bodySm),
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
                        text: 'Reset',
                        variant: AppButtonVariant.outline,
                        onPressed: () {
                          setState(() {
                            for (var item in _stackItems) {
                              item.isConfirmed = false;
                            }
                          });
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: AppButton(
                        text: 'Confirm Stack & Continue',
                        isLoading: _isConfirming,
                        onPressed: () async {
                          setState(() => _isConfirming = true);
                          await Future.delayed(const Duration(milliseconds: 700));
                          if (mounted) {
                            setState(() => _isConfirming = false);
                            if (widget.onConfirmStack != null) {
                              widget.onConfirmStack!();
                            } else if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Technology stack confirmed!')),
                              );
                            }
                          }
                        },
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

  Widget _buildMiniPill(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Text(
        label,
        style: AppTypography.codeSm.copyWith(color: color, fontSize: 10),
      ),
    );
  }
}
