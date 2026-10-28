import 'package:flutter/material.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_typography.dart';

/// Full-featured in-app code editor & viewer with:
/// - Manual code editing & Save to server
/// - Search and Find with line highlighting and match navigation
/// - Line numbers gutter
/// - Sleek dark IDE aesthetics
class WorkspaceFileEditorDialog extends StatefulWidget {
  final String filePath;
  final String fileName;
  final String initialContent;
  final Future<bool> Function(String newContent) onSave;

  const WorkspaceFileEditorDialog({
    super.key,
    required this.filePath,
    required this.fileName,
    required this.initialContent,
    required this.onSave,
  });

  @override
  State<WorkspaceFileEditorDialog> createState() => _WorkspaceFileEditorDialogState();
}

class _WorkspaceFileEditorDialogState extends State<WorkspaceFileEditorDialog> {
  late final TextEditingController _contentController;
  late final TextEditingController _searchController;
  bool _isEditing = false;
  bool _isSaving = false;
  bool _isSearchVisible = false;
  String _searchQuery = '';
  final List<int> _matchingLineIndices = [];
  int _currentMatchIndex = 0;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _contentController = TextEditingController(text: widget.initialContent);
    _searchController = TextEditingController();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _contentController.dispose();
    _searchController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim().toLowerCase();
    setState(() {
      _searchQuery = query;
      _matchingLineIndices.clear();
      _currentMatchIndex = 0;

      if (query.isNotEmpty) {
        final lines = _contentController.text.split('\n');
        for (int i = 0; i < lines.length; i++) {
          if (lines[i].toLowerCase().contains(query)) {
            _matchingLineIndices.add(i);
          }
        }
      }
    });
  }

  void _nextMatch() {
    if (_matchingLineIndices.isEmpty) return;
    setState(() {
      _currentMatchIndex = (_currentMatchIndex + 1) % _matchingLineIndices.length;
    });
  }

  void _prevMatch() {
    if (_matchingLineIndices.isEmpty) return;
    setState(() {
      _currentMatchIndex = (_currentMatchIndex - 1 + _matchingLineIndices.length) % _matchingLineIndices.length;
    });
  }

  Future<void> _handleSave() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    final success = await widget.onSave(_contentController.text);
    if (!mounted) return;
    setState(() {
      _isSaving = false;
      if (success) {
        _isEditing = false;
      }
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          success ? 'Saved ${widget.fileName} successfully!' : 'Failed to save ${widget.fileName}',
        ),
        backgroundColor: success ? AppColors.statusSuccess : AppColors.statusError,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final lines = _contentController.text.split('\n');
    final lineCount = lines.length;

    return Dialog(
      backgroundColor: AppColors.surfaceMain,
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 16),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppColors.borderSubtle),
      ),
      child: Container(
        width: double.maxFinite,
        height: MediaQuery.of(context).size.height * 0.88,
        padding: const EdgeInsets.all(12),
        child: Column(
          children: [
            // Top Bar
            Row(
              children: [
                const Icon(Icons.code, size: 18, color: AppColors.lavender),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.fileName,
                        style: AppTypography.headlineSm.copyWith(fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        '${widget.filePath} • $lineCount lines',
                        style: AppTypography.codeSm.copyWith(
                          fontSize: 10,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),

                // Search Toggle Button
                IconButton(
                  tooltip: 'Search & Find',
                  icon: Icon(
                    Icons.search,
                    size: 18,
                    color: _isSearchVisible ? AppColors.lavender : AppColors.textSecondary,
                  ),
                  onPressed: () {
                    setState(() {
                      _isSearchVisible = !_isSearchVisible;
                      if (!_isSearchVisible) {
                        _searchController.clear();
                      }
                    });
                  },
                ),

                // Edit / View Toggle Button
                IconButton(
                  tooltip: _isEditing ? 'View Mode' : 'Edit Mode',
                  icon: Icon(
                    _isEditing ? Icons.visibility : Icons.edit,
                    size: 18,
                    color: _isEditing ? const Color(0xFF00E5FF) : AppColors.textSecondary,
                  ),
                  onPressed: () {
                    setState(() => _isEditing = !_isEditing);
                  },
                ),

                // Save Button (visible when editing)
                if (_isEditing)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.statusSuccess,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      ),
                      icon: _isSaving
                          ? const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                            )
                          : const Icon(Icons.save, size: 14),
                      label: Text(
                        _isSaving ? 'Saving' : 'SAVE',
                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                      ),
                      onPressed: _isSaving ? null : _handleSave,
                    ),
                  ),

                // Close Button
                IconButton(
                  icon: const Icon(Icons.close, size: 18, color: AppColors.textSecondary),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),

            // Search Bar
            if (_isSearchVisible) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: AppColors.surfaceElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.lavender.withOpacity(0.4)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.find_in_page_outlined, size: 16, color: AppColors.lavender),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        style: AppTypography.codeSm.copyWith(color: AppColors.textPrimary),
                        decoration: InputDecoration(
                          hintText: 'Find in file...',
                          hintStyle: AppTypography.codeSm.copyWith(color: AppColors.textMuted),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                      ),
                    ),
                    if (_matchingLineIndices.isNotEmpty) ...[
                      Text(
                        '${_currentMatchIndex + 1} of ${_matchingLineIndices.length} matches',
                        style: AppTypography.codeSm.copyWith(
                          fontSize: 10,
                          color: AppColors.lavender,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_up, size: 18, color: AppColors.lavender),
                        onPressed: _prevMatch,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.keyboard_arrow_down, size: 18, color: AppColors.lavender),
                        onPressed: _nextMatch,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ] else if (_searchQuery.isNotEmpty) ...[
                      Text(
                        '0 matches',
                        style: AppTypography.codeSm.copyWith(fontSize: 10, color: AppColors.statusError),
                      ),
                    ],
                  ],
                ),
              ),
            ],

            const SizedBox(height: 10),
            const Divider(color: AppColors.borderSubtle, height: 1),
            const SizedBox(height: 6),

            // Code Editor & Viewer Area
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: const Color(0xFF0F0E17),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppColors.borderSubtle),
                ),
                child: _isEditing
                    ? Padding(
                        padding: const EdgeInsets.all(10),
                        child: TextField(
                          controller: _contentController,
                          maxLines: null,
                          expands: true,
                          keyboardType: TextInputType.multiline,
                          style: AppTypography.codeSm.copyWith(
                            fontSize: 11,
                            color: AppColors.textPrimary,
                            height: 1.4,
                          ),
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      )
                    : Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: true,
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Line numbers gutter
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8),
                                decoration: const BoxDecoration(
                                  border: Border(right: BorderSide(color: Color(0xFF232136), width: 1)),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: List.generate(lineCount, (i) {
                                    final isMatch = _matchingLineIndices.contains(i);
                                    final isCurrent = _matchingLineIndices.isNotEmpty &&
                                        _matchingLineIndices[_currentMatchIndex] == i;

                                    return Text(
                                      '${i + 1}',
                                      style: AppTypography.codeSm.copyWith(
                                        fontSize: 10,
                                        height: 1.4,
                                        color: isCurrent
                                            ? const Color(0xFF00E5FF)
                                            : (isMatch ? AppColors.lavender : const Color(0xFF555169)),
                                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                                      ),
                                    );
                                  }),
                                ),
                              ),
                              const SizedBox(width: 8),

                              // Code content with search highlight
                              Expanded(
                                child: SingleChildScrollView(
                                  scrollDirection: Axis.horizontal,
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: List.generate(lineCount, (i) {
                                      final line = lines[i];
                                      final isMatch = _matchingLineIndices.contains(i);
                                      final isCurrent = _matchingLineIndices.isNotEmpty &&
                                          _matchingLineIndices[_currentMatchIndex] == i;

                                      return Container(
                                        color: isCurrent
                                            ? const Color(0xFF00E5FF).withOpacity(0.2)
                                            : (isMatch ? AppColors.lavender.withOpacity(0.12) : Colors.transparent),
                                        padding: const EdgeInsets.symmetric(horizontal: 4),
                                        child: Text(
                                          line.isEmpty ? ' ' : line,
                                          style: AppTypography.codeSm.copyWith(
                                            fontSize: 11,
                                            height: 1.4,
                                            color: isCurrent
                                                ? Colors.white
                                                : (isMatch ? const Color(0xFFE0DEF4) : AppColors.textPrimary),
                                          ),
                                        ),
                                      );
                                    }),
                                  ),
                                ),
                              ),
                            ],
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
}
