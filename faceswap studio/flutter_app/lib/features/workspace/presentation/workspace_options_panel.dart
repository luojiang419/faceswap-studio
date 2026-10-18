import 'package:flutter/material.dart';

typedef WorkspaceOptionsUpdater =
    Future<void> Function(Map<String, dynamic> payload, {bool clearPreview});

class WorkspaceFloatingOptionsOverlay extends StatefulWidget {
  const WorkspaceFloatingOptionsOverlay({
    required this.compact,
    required this.collapsedWidth,
    required this.panelWidth,
    required this.minPanelWidth,
    required this.maxPanelWidth,
    required this.onPanelWidthChanged,
    required this.onPanelWidthChangeEnd,
    required this.child,
    super.key,
  });

  final bool compact;
  final double collapsedWidth;
  final double panelWidth;
  final double minPanelWidth;
  final double maxPanelWidth;
  final ValueChanged<double> onPanelWidthChanged;
  final Future<void> Function(double width) onPanelWidthChangeEnd;
  final Widget child;

  @override
  State<WorkspaceFloatingOptionsOverlay> createState() =>
      _WorkspaceFloatingOptionsOverlayState();
}

class _WorkspaceFloatingOptionsOverlayState
    extends State<WorkspaceFloatingOptionsOverlay> {
  bool _expanded = false;
  double? _dragPanelWidth;

  double _clampPanelWidth(double value) {
    return value.clamp(widget.minPanelWidth, widget.maxPanelWidth).toDouble();
  }

  void _handleResizeStart(DragStartDetails details) {
    _dragPanelWidth = widget.panelWidth;
  }

  void _handleResizeUpdate(DragUpdateDetails details) {
    final nextWidth = _clampPanelWidth(
      (_dragPanelWidth ?? widget.panelWidth) - details.delta.dx,
    );
    _dragPanelWidth = nextWidth;
    widget.onPanelWidthChanged(nextWidth);
  }

  void _handleResizeEnd([DragEndDetails? _]) {
    final nextWidth = _clampPanelWidth(_dragPanelWidth ?? widget.panelWidth);
    _dragPanelWidth = null;
    widget.onPanelWidthChangeEnd(nextWidth);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Positioned(
      top: widget.compact ? 12 : 16,
      right: 0,
      bottom: widget.compact ? 12 : 16,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        width: _expanded ? widget.panelWidth : widget.collapsedWidth,
        decoration: BoxDecoration(
          color: theme.cardTheme.color,
          borderRadius: BorderRadius.circular(_expanded ? 22 : 18),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.42),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(
                alpha: theme.brightness == Brightness.dark ? 0.32 : 0.14,
              ),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: _expanded
            ? _WorkspaceOptionsPanelFrame(
                onResizeStart: _handleResizeStart,
                onResizeUpdate: _handleResizeUpdate,
                onResizeEnd: _handleResizeEnd,
                onClose: () {
                  setState(() {
                    _expanded = false;
                  });
                },
                child: widget.child,
              )
            : Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    setState(() {
                      _expanded = true;
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.tune_rounded,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(height: 12),
                        RotatedBox(
                          quarterTurns: 3,
                          child: Text(
                            '参数面板',
                            maxLines: 1,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        const Spacer(),
                        const Icon(Icons.keyboard_double_arrow_left_rounded),
                      ],
                    ),
                  ),
                ),
              ),
      ),
    );
  }
}

class _WorkspaceOptionsPanelFrame extends StatelessWidget {
  const _WorkspaceOptionsPanelFrame({
    required this.onResizeStart,
    required this.onResizeUpdate,
    required this.onResizeEnd,
    required this.onClose,
    required this.child,
  });

  final GestureDragStartCallback onResizeStart;
  final GestureDragUpdateCallback onResizeUpdate;
  final GestureDragEndCallback onResizeEnd;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(child: child),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: 20,
          child: MouseRegion(
            cursor: SystemMouseCursors.resizeLeftRight,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onHorizontalDragStart: onResizeStart,
              onHorizontalDragUpdate: onResizeUpdate,
              onHorizontalDragEnd: onResizeEnd,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  width: 4,
                  margin: const EdgeInsets.symmetric(vertical: 20),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.outlineVariant.withValues(alpha: 0.7),
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned(
          top: 10,
          right: 10,
          child: Tooltip(
            message: '折叠参数面板',
            child: IconButton.filledTonal(
              onPressed: onClose,
              icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
            ),
          ),
        ),
      ],
    );
  }
}

class WorkspaceOptionsPanel extends StatefulWidget {
  const WorkspaceOptionsPanel({
    required this.compact,
    required this.busy,
    required this.targetMediaType,
    required this.targetVideoFrameTotal,
    required this.schema,
    required this.state,
    required this.onUpdateOptions,
    required this.onResetOptions,
    super.key,
  });

  final bool compact;
  final bool busy;
  final String? targetMediaType;
  final int? targetVideoFrameTotal;
  final WorkspaceOptionsSchema? schema;
  final WorkspaceOptionsState state;
  final WorkspaceOptionsUpdater onUpdateOptions;
  final Future<void> Function() onResetOptions;

  @override
  State<WorkspaceOptionsPanel> createState() => _WorkspaceOptionsPanelState();
}

class _WorkspaceOptionsPanelState extends State<WorkspaceOptionsPanel> {
  final Map<String, double> _numericDrafts = <String, double>{};
  late final Map<String, TextEditingController> _textControllers;
  final Map<String, List<TextEditingController>> _listControllers =
      <String, List<TextEditingController>>{};

  @override
  void initState() {
    super.initState();
    _textControllers = <String, TextEditingController>{
      'output_video_fps': TextEditingController(),
      'preview_frame_number': TextEditingController(),
    };
    _syncWithState();
  }

  @override
  void didUpdateWidget(covariant WorkspaceOptionsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncWithState();
  }

  @override
  void dispose() {
    for (final controller in _textControllers.values) {
      controller.dispose();
    }
    for (final controllers in _listControllers.values) {
      for (final controller in controllers) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  void _syncWithState() {
    final schema = widget.schema;
    if (schema == null) {
      return;
    }

    for (final field in schema.fields.values) {
      final value = widget.state.options[field.key];
      if (field.usesTextInput) {
        final controller = _textControllers[field.key];
        if (controller != null) {
          final nextText = field.formatEditableValue(value);
          if (controller.text != nextText) {
            controller.text = nextText;
          }
        }
        continue;
      }
      if (field.control == 'rgba') {
        final values = widget.state.intListValue(field.key, fallbackLength: 4);
        final controllers = _listControllers.putIfAbsent(
          field.key,
          () => List<TextEditingController>.generate(
            4,
            (_) => TextEditingController(),
          ),
        );
        for (var index = 0; index < controllers.length; index++) {
          final nextText = index < values.length ? '${values[index]}' : '0';
          if (controllers[index].text != nextText) {
            controllers[index].text = nextText;
          }
        }
        continue;
      }
      if (field.isNumeric) {
        _numericDrafts[field.key] = field.primaryDoubleValue(value);
      }
    }
  }

  Future<void> _applyTextFieldValue(WorkspaceOptionField field) async {
    final controller = _textControllers[field.key];
    if (controller == null) {
      return;
    }
    final parsedValue = field.parseEditableValue(controller.text);
    if (parsedValue == null) {
      _syncWithState();
      setState(() {});
      return;
    }
    await widget.onUpdateOptions(<String, dynamic>{field.key: parsedValue});
  }

  Future<void> _applyRgbaFieldValue(WorkspaceOptionField field) async {
    final controllers = _listControllers[field.key];
    if (controllers == null || controllers.length != 4) {
      return;
    }
    final minimum = (field.minimum ?? 0).round();
    final maximum = (field.maximum ?? 255).round();
    final currentValues = widget.state.intListValue(
      field.key,
      fallbackLength: 4,
    );
    final nextValues = <int>[];
    for (var index = 0; index < controllers.length; index++) {
      final rawValue = controllers[index].text.trim();
      final parsedValue = int.tryParse(rawValue);
      final fallbackValue = index < currentValues.length
          ? currentValues[index]
          : minimum;
      final normalizedValue = parsedValue == null
          ? fallbackValue
          : parsedValue.clamp(minimum, maximum);
      nextValues.add(normalizedValue);
    }
    await widget.onUpdateOptions(<String, dynamic>{field.key: nextValues});
  }

  String? get _targetMediaType =>
      widget.targetMediaType ?? widget.state.targetMediaType;

  String get _selectedOutputVideoEncoder {
    final value = widget.state.options['output_video_encoder'];
    return value == null ? '' : '$value';
  }

  bool get _isProResOutputSelected =>
      _selectedOutputVideoEncoder == 'prores_ks';

  String _displayChoiceLabel(WorkspaceOptionField field, String choice) {
    if (field.choiceLabels.containsKey(choice)) {
      return field.choiceLabels[choice]!;
    }
    if (field.key == 'output_video_encoder' && choice == 'prores_ks') {
      return 'ProRes 422 (MOV)';
    }
    if (choice == 'none') {
      return '不限';
    }
    return choice;
  }

  String? _fieldHelperText(WorkspaceOptionField field) {
    final selected = field.selectValue(widget.state.options[field.key]);
    if (selected != null && field.choiceLabels.containsKey(selected)) {
      return '外网下载 · 自动检测并使用系统代理，已安装模型会复用。';
    }
    if (field.key == 'output_video_encoder') {
      return _isProResOutputSelected
          ? '当前会输出 .mov，视频预设不适用。'
          : '选择 ProRes 422 (MOV) 时会自动输出 .mov。';
    }
    if (field.key == 'output_video_quality' && _isProResOutputSelected) {
      return '当前映射为 ProRes 质量等级，数值越高画质越高。';
    }
    return null;
  }

  bool _isFieldVisible(WorkspaceOptionField field) {
    if (!field.supportsTargetMediaType(_targetMediaType)) {
      return false;
    }
    if (field.key == 'output_video_preset' && _isProResOutputSelected) {
      return false;
    }
    if (!field.isSatisfiedByProcessors(
      widget.state.stringListValue('processors'),
    )) {
      return false;
    }
    if (!field.matchesDependency(widget.state.options)) {
      return false;
    }
    return true;
  }

  List<WorkspaceOptionField> _visibleFieldsForPanel(String panel) {
    final schema = widget.schema;
    if (schema == null) {
      return const <WorkspaceOptionField>[];
    }
    return schema.fields.values
        .where((field) => field.panel == panel && _isFieldVisible(field))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final compact = widget.compact;
    final sectionSpacing = compact ? 12.0 : 14.0;
    final commonFields = _visibleFieldsForPanel('common');
    final advancedFields = _visibleFieldsForPanel('advanced');
    final loading = widget.schema == null || widget.state.options.isEmpty;

    return Container(
      padding: EdgeInsets.all(compact ? 14 : 18),
      decoration: BoxDecoration(
        color: theme.cardTheme.color,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35),
        ),
      ),
      child: DefaultTabController(
        length: 2,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '参数面板',
                    style:
                        (compact
                                ? theme.textTheme.titleSmall
                                : theme.textTheme.titleMedium)
                            ?.copyWith(fontWeight: FontWeight.w800),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: widget.busy ? null : () => widget.onResetOptions(),
                  icon: Icon(
                    Icons.restart_alt_rounded,
                    size: compact ? 18 : 20,
                  ),
                  label: const Text('重置默认'),
                  style: FilledButton.styleFrom(
                    minimumSize: Size(0, compact ? 36 : 40),
                  ),
                ),
                const SizedBox(width: 48),
              ],
            ),
            SizedBox(height: compact ? 8 : 10),
            Text(
              '直接写入工作台参数草稿，后续预览与入队都会使用这里的当前值。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.35,
              ),
            ),
            if (_targetMediaType == 'video' && _isProResOutputSelected) ...[
              SizedBox(height: compact ? 10 : 12),
              Container(
                width: double.infinity,
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 12 : 14,
                  vertical: compact ? 10 : 12,
                ),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(
                    alpha: 0.45,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: theme.colorScheme.primary.withValues(alpha: 0.18),
                  ),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.video_settings_rounded,
                      size: compact ? 18 : 20,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '当前使用 ProRes 422，输出容器会自动切换为 .mov，视频预设已自动隐藏。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface,
                          height: 1.35,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            SizedBox(height: compact ? 12 : 14),
            if (loading)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(
                        width: 26,
                        height: 26,
                        child: CircularProgressIndicator(strokeWidth: 2.4),
                      ),
                      const SizedBox(height: 12),
                      Text('正在加载参数面板', style: theme.textTheme.bodyMedium),
                    ],
                  ),
                ),
              )
            else ...[
              const TabBar(
                tabs: [
                  Tab(text: '常用参数'),
                  Tab(text: '进阶控制'),
                ],
              ),
              SizedBox(height: compact ? 10 : 12),
              Expanded(
                child: TabBarView(
                  children: [
                    _buildOptionTab(
                      context,
                      fields: commonFields,
                      sectionSpacing: sectionSpacing,
                    ),
                    _buildOptionTab(
                      context,
                      fields: advancedFields,
                      sectionSpacing: sectionSpacing,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildOptionTab(
    BuildContext context, {
    required List<WorkspaceOptionField> fields,
    required double sectionSpacing,
  }) {
    final theme = Theme.of(context);
    final children = _buildSections(context, fields, sectionSpacing);
    if (children.isEmpty) {
      return Center(
        child: Text(
          '当前目标类型暂无可用参数',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Scrollbar(
      child: SingleChildScrollView(
        padding: EdgeInsets.only(right: widget.compact ? 4 : 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    );
  }

  List<Widget> _buildSections(
    BuildContext context,
    List<WorkspaceOptionField> fields,
    double sectionSpacing,
  ) {
    final grouped = <String, List<WorkspaceOptionField>>{};
    final sectionLabels = <String, String>{};
    final orderedSections = <String>[];

    for (final field in fields) {
      if (!grouped.containsKey(field.section)) {
        grouped[field.section] = <WorkspaceOptionField>[];
        orderedSections.add(field.section);
        sectionLabels[field.section] = field.sectionLabel;
      }
      grouped[field.section]!.add(field);
    }

    final widgets = <Widget>[];
    for (final section in orderedSections) {
      final sectionFields = grouped[section];
      if (sectionFields == null || sectionFields.isEmpty) {
        continue;
      }
      widgets.add(
        _WorkspaceSectionTitle(title: sectionLabels[section] ?? section),
      );
      widgets.add(SizedBox(height: widget.compact ? 8 : 10));
      widgets.addAll(
        sectionFields.map(
          (field) => Padding(
            padding: EdgeInsets.only(bottom: sectionSpacing),
            child: _buildField(context, field),
          ),
        ),
      );
    }
    return widgets;
  }

  Widget _buildField(BuildContext context, WorkspaceOptionField field) {
    if (field.type == 'multi_select') {
      return _buildMultiSelectField(context, field);
    }
    if (field.type == 'select') {
      return _buildSelectField(context, field);
    }
    if (field.type == 'bool') {
      return _buildBoolField(context, field);
    }
    if (field.control == 'rgba') {
      return _buildRgbaField(context, field);
    }
    if (field.control == 'tuple4') {
      return _buildTuple4Field(context, field);
    }
    if (field.control == 'uniform_tuple4') {
      return _buildUniformTupleField(context, field);
    }
    if (field.control == 'range') {
      return _buildRangeField(
        context,
        field,
        minimum: field.minimum ?? 0,
        maximum: field.maximum ?? 100,
      );
    }
    if (field.control == 'frame_range') {
      final totalFrames = (widget.targetVideoFrameTotal ?? 0)
          .clamp(0, 1 << 20)
          .toDouble();
      return _buildRangeField(
        context,
        field,
        minimum: 0,
        maximum: totalFrames <= 0 ? 1 : totalFrames,
      );
    }
    if (field.usesTextInput) {
      return _buildTextInputField(context, field);
    }
    return _buildNumericSliderField(context, field);
  }

  Widget _buildMultiSelectField(
    BuildContext context,
    WorkspaceOptionField field,
  ) {
    final theme = Theme.of(context);
    final selectedValues = widget.state.stringListValue(field.key);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          field.label,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: field.choices.map((choice) {
            final selected = selectedValues.contains(choice);
            return FilterChip(
              selected: selected,
              label: Text(_displayChoiceLabel(field, choice)),
              onSelected: widget.busy
                  ? null
                  : (nextSelected) {
                      final nextValues = List<String>.from(selectedValues);
                      if (nextSelected) {
                        if (!nextValues.contains(choice)) {
                          nextValues.add(choice);
                        }
                      } else {
                        nextValues.remove(choice);
                      }
                      widget.onUpdateOptions(<String, dynamic>{
                        field.key: nextValues,
                      });
                    },
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildSelectField(BuildContext context, WorkspaceOptionField field) {
    final currentValue = field.selectValue(widget.state.options[field.key]);
    return DropdownButtonFormField<String>(
      initialValue: currentValue,
      items: field.choices
          .map(
            (choice) => DropdownMenuItem<String>(
              value: choice,
              child: Text(
                _displayChoiceLabel(field, choice),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: widget.busy
          ? null
          : (nextValue) {
              if (nextValue == null) {
                return;
              }
              widget.onUpdateOptions(<String, dynamic>{
                field.key: field.normalizeSelectSubmission(nextValue),
              });
            },
      decoration: InputDecoration(
        labelText: field.label,
        helperText: _fieldHelperText(field),
      ),
    );
  }

  Widget _buildBoolField(BuildContext context, WorkspaceOptionField field) {
    final theme = Theme.of(context);
    final value = widget.state.boolValue(field.key);
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      value: value,
      onChanged: widget.busy
          ? null
          : (nextValue) {
              widget.onUpdateOptions(<String, dynamic>{field.key: nextValue});
            },
      title: Text(
        field.label,
        style: theme.textTheme.bodyMedium?.copyWith(
          fontWeight: FontWeight.w700,
        ),
      ),
      subtitle: Text(
        value ? '当前已启用。' : '当前已关闭。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _buildRgbaField(BuildContext context, WorkspaceOptionField field) {
    final theme = Theme.of(context);
    final labels = const <String>['R', 'G', 'B', 'A'];
    final controllers = _listControllers.putIfAbsent(
      field.key,
      () => List<TextEditingController>.generate(
        4,
        (_) => TextEditingController(),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          field.label,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: List<Widget>.generate(labels.length, (index) {
            return SizedBox(
              width: 72,
              child: TextField(
                controller: controllers[index],
                enabled: !widget.busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: labels[index],
                  isDense: true,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          onPressed: widget.busy ? null : () => _applyRgbaFieldValue(field),
          icon: const Icon(Icons.check_rounded),
          label: const Text('应用颜色'),
          style: FilledButton.styleFrom(
            minimumSize: Size(0, widget.compact ? 38 : 40),
          ),
        ),
      ],
    );
  }

  Widget _buildTuple4Field(BuildContext context, WorkspaceOptionField field) {
    final values = widget.state.intListValue(field.key, fallbackLength: 4);
    final labels = const <String>['上', '右', '下', '左'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          field.label,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        for (var index = 0; index < labels.length; index++) ...[
          Text(labels[index]),
          Slider(
            value: (index < values.length ? values[index] : 0).toDouble(),
            min: field.minimum ?? 0,
            max: field.maximum ?? 100,
            divisions: field.divisions,
            label: '${index < values.length ? values[index] : 0}',
            onChanged: widget.busy
                ? null
                : (nextValue) {
                    final nextValues = List<int>.from(values);
                    while (nextValues.length < 4) {
                      nextValues.add(0);
                    }
                    nextValues[index] = nextValue.round();
                    widget.onUpdateOptions(<String, dynamic>{
                      field.key: nextValues,
                    });
                  },
          ),
        ],
      ],
    );
  }

  Widget _buildUniformTupleField(
    BuildContext context,
    WorkspaceOptionField field,
  ) {
    final values = widget.state.intListValue(field.key, fallbackLength: 4);
    final currentValue = values.isNotEmpty ? values.first.toDouble() : 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                field.label,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text('${currentValue.round()}'),
          ],
        ),
        Slider(
          value: currentValue.clamp(
            field.minimum ?? 0.0,
            field.maximum ?? 100.0,
          ),
          min: field.minimum ?? 0.0,
          max: field.maximum ?? 100.0,
          divisions: field.divisions,
          label: '${currentValue.round()}',
          onChanged: widget.busy
              ? null
              : (nextValue) {
                  widget.onUpdateOptions(<String, dynamic>{
                    field.key: List<int>.filled(4, nextValue.round()),
                  });
                },
        ),
      ],
    );
  }

  Widget _buildRangeField(
    BuildContext context,
    WorkspaceOptionField field, {
    required double minimum,
    required double maximum,
  }) {
    final theme = Theme.of(context);
    final endKey = field.pairedKey;
    if (endKey == null) {
      return const SizedBox.shrink();
    }

    final startValue = widget.state.optionalDoubleValue(field.key) ?? minimum;
    final endValue = widget.state.optionalDoubleValue(endKey) ?? maximum;
    final normalizedValues = RangeValues(
      startValue.clamp(minimum, maximum),
      endValue.clamp(minimum, maximum),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                field.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              '${normalizedValues.start.round()} - ${normalizedValues.end.round()}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        RangeSlider(
          values: normalizedValues,
          min: minimum,
          max: maximum,
          divisions: (maximum - minimum).round(),
          labels: RangeLabels(
            '${normalizedValues.start.round()}',
            '${normalizedValues.end.round()}',
          ),
          onChanged: widget.busy
              ? null
              : (nextValues) {
                  setState(() {
                    _numericDrafts[field.key] = nextValues.start;
                    _numericDrafts[endKey] = nextValues.end;
                  });
                },
          onChangeEnd: widget.busy
              ? null
              : (nextValues) {
                  final start = nextValues.start.round();
                  final end = nextValues.end.round();
                  final nextPayload = <String, dynamic>{
                    field.key: start <= minimum ? null : start,
                    endKey: end >= maximum ? null : end,
                  };
                  widget.onUpdateOptions(nextPayload);
                },
        ),
      ],
    );
  }

  Widget _buildTextInputField(
    BuildContext context,
    WorkspaceOptionField field,
  ) {
    final controller = _textControllers[field.key]!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          field.label,
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: controller,
                enabled: !widget.busy,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  hintText: _textFieldHint(field),
                  helperText: _fieldRangeHint(field),
                ),
                onSubmitted: (_) => _applyTextFieldValue(field),
              ),
            ),
            const SizedBox(width: 10),
            FilledButton.tonalIcon(
              onPressed: widget.busy ? null : () => _applyTextFieldValue(field),
              icon: const Icon(Icons.check_rounded),
              label: const Text('应用'),
              style: FilledButton.styleFrom(
                minimumSize: Size(0, widget.compact ? 38 : 40),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildNumericSliderField(
    BuildContext context,
    WorkspaceOptionField field,
  ) {
    final theme = Theme.of(context);
    final value = widget.state.options[field.key];
    final currentValue =
        _numericDrafts[field.key] ?? field.primaryDoubleValue(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                field.label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Text(
              field.formatValue(field.castSliderValue(currentValue)),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        Slider(
          value: currentValue.clamp(field.minimum ?? 0.0, field.maximum ?? 1.0),
          min: field.minimum ?? 0.0,
          max: field.maximum ?? 1.0,
          divisions: field.divisions,
          label: field.formatValue(field.castSliderValue(currentValue)),
          onChanged: widget.busy
              ? null
              : (nextValue) {
                  setState(() {
                    _numericDrafts[field.key] = nextValue;
                  });
                },
          onChangeEnd: widget.busy
              ? null
              : (nextValue) {
                  final normalizedValue = field.castSliderValue(nextValue);
                  widget.onUpdateOptions(<String, dynamic>{
                    field.key: normalizedValue,
                  });
                },
        ),
      ],
    );
  }

  String _textFieldHint(WorkspaceOptionField field) {
    return switch (field.key) {
      'preview_frame_number' => '输入预览帧号',
      _ => '输入输出 FPS',
    };
  }

  String? _fieldRangeHint(WorkspaceOptionField field) {
    if (field.key == 'preview_frame_number' &&
        widget.targetVideoFrameTotal != null) {
      return '范围 0 - ${widget.targetVideoFrameTotal}';
    }
    if (field.minimum == null || field.maximum == null) {
      return null;
    }
    return '范围 ${field.minimum} - ${field.maximum}';
  }
}

class _WorkspaceSectionTitle extends StatelessWidget {
  const _WorkspaceSectionTitle({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(
      title,
      style: theme.textTheme.labelLarge?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        letterSpacing: 0.4,
        fontWeight: FontWeight.w700,
      ),
    );
  }
}

class WorkspaceOptionsSchema {
  const WorkspaceOptionsSchema({
    required this.version,
    required this.targetMediaType,
    required this.fields,
  });

  factory WorkspaceOptionsSchema.fromJson(Map<String, dynamic> json) {
    final rawFields =
        (json['fields'] as Map<String, dynamic>? ?? const <String, dynamic>{})
            .cast<String, dynamic>();
    return WorkspaceOptionsSchema(
      version: (json['version'] as num?)?.toInt() ?? 1,
      targetMediaType: json['target_media_type'] as String?,
      fields: rawFields.map(
        (key, value) => MapEntry(
          key,
          WorkspaceOptionField.fromJson(key, value as Map<String, dynamic>),
        ),
      ),
    );
  }

  final int version;
  final String? targetMediaType;
  final Map<String, WorkspaceOptionField> fields;
}

class WorkspaceOptionsState {
  const WorkspaceOptionsState({
    required this.version,
    required this.targetMediaType,
    required this.options,
  });

  const WorkspaceOptionsState.empty()
    : version = 1,
      targetMediaType = null,
      options = const <String, dynamic>{};

  factory WorkspaceOptionsState.fromJson(Map<String, dynamic> json) {
    final rawOptions =
        (json['options'] as Map<String, dynamic>? ?? const <String, dynamic>{})
            .cast<String, dynamic>();
    return WorkspaceOptionsState(
      version: (json['version'] as num?)?.toInt() ?? 1,
      targetMediaType: json['target_media_type'] as String?,
      options: Map<String, dynamic>.from(rawOptions),
    );
  }

  final int version;
  final String? targetMediaType;
  final Map<String, dynamic> options;

  List<String> stringListValue(String key) {
    final rawValue = options[key];
    if (rawValue is List<dynamic>) {
      return rawValue.map((item) => '$item').toList();
    }
    return const <String>[];
  }

  List<int> intListValue(String key, {int fallbackLength = 0}) {
    final rawValue = options[key];
    if (rawValue is! List<dynamic>) {
      return List<int>.filled(fallbackLength, 0);
    }
    final values = rawValue
        .map((item) => item is num ? item.toInt() : int.tryParse('$item') ?? 0)
        .toList();
    if (values.length >= fallbackLength) {
      return values;
    }
    return <int>[
      ...values,
      ...List<int>.filled(fallbackLength - values.length, 0),
    ];
  }

  bool boolValue(String key) {
    final rawValue = options[key];
    if (rawValue is bool) {
      return rawValue;
    }
    if (rawValue is String) {
      return rawValue.toLowerCase() == 'true';
    }
    return rawValue == true;
  }

  double? optionalDoubleValue(String key) {
    final rawValue = options[key];
    if (rawValue == null) {
      return null;
    }
    if (rawValue is num) {
      return rawValue.toDouble();
    }
    return double.tryParse('$rawValue');
  }
}

class WorkspaceOptionField {
  const WorkspaceOptionField({
    required this.key,
    required this.type,
    required this.panel,
    required this.section,
    required this.sectionLabel,
    required this.label,
    required this.choices,
    this.choiceLabels = const <String, String>{},
    required this.visibleFor,
    required this.dependsValues,
    required this.requiresProcessors,
    this.dependsOn,
    this.minimum,
    this.maximum,
    this.step,
    this.control,
    this.pairedKey,
    this.pairLabel,
  });

  factory WorkspaceOptionField.fromJson(String key, Map<String, dynamic> json) {
    return WorkspaceOptionField(
      key: key,
      type: '${json['type'] ?? 'select'}',
      panel: '${json['panel'] ?? 'common'}',
      section: '${json['section'] ?? 'misc'}',
      sectionLabel: '${json['section_label'] ?? json['section'] ?? 'misc'}',
      label: '${json['label'] ?? key}',
      choiceLabels:
          (json['choice_labels'] as Map<String, dynamic>? ??
                  const <String, dynamic>{})
              .map((key, value) => MapEntry(key, '$value')),
      choices: (json['choices'] as List<dynamic>? ?? const <dynamic>[])
          .map((item) => '$item')
          .toList(),
      visibleFor:
          (json['visible_for'] as List<dynamic>? ?? const <dynamic>['all'])
              .map((item) => '$item')
              .toList(),
      dependsValues:
          (json['depends_values'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => '$item')
              .toList(),
      requiresProcessors:
          (json['requires_processors'] as List<dynamic>? ?? const <dynamic>[])
              .map((item) => '$item')
              .toList(),
      dependsOn: json['depends_on'] as String?,
      minimum: (json['minimum'] as num?)?.toDouble(),
      maximum: (json['maximum'] as num?)?.toDouble(),
      step: (json['step'] as num?)?.toDouble(),
      control: json['control'] as String?,
      pairedKey: json['paired_key'] as String?,
      pairLabel: json['pair_label'] as String?,
    );
  }

  final String key;
  final String type;
  final String panel;
  final String section;
  final String sectionLabel;
  final String label;
  final List<String> choices;
  final Map<String, String> choiceLabels;
  final List<String> visibleFor;
  final List<String> dependsValues;
  final List<String> requiresProcessors;
  final String? dependsOn;
  final double? minimum;
  final double? maximum;
  final double? step;
  final String? control;
  final String? pairedKey;
  final String? pairLabel;

  bool get isNumeric => type == 'int' || type == 'float';

  bool get usesTextInput =>
      key == 'output_video_fps' || key == 'preview_frame_number';

  bool supportsTargetMediaType(String? targetMediaType) {
    if (visibleFor.contains('all')) {
      return true;
    }
    if (targetMediaType == null) {
      return false;
    }
    return visibleFor.contains(targetMediaType);
  }

  bool isSatisfiedByProcessors(List<String> processors) {
    if (requiresProcessors.isEmpty) {
      return true;
    }
    return requiresProcessors.any(processors.contains);
  }

  bool matchesDependency(Map<String, dynamic> options) {
    if (dependsOn == null || dependsValues.isEmpty) {
      return true;
    }
    final dependencyValue = options[dependsOn!];
    if (dependencyValue is List<dynamic>) {
      final currentValues = dependencyValue.map((item) => '$item').toSet();
      return dependsValues.any(currentValues.contains);
    }
    if (dependencyValue == null) {
      return false;
    }
    return dependsValues.contains('$dependencyValue');
  }

  String? selectValue(dynamic value) {
    if (value == null && choices.contains('none')) {
      return 'none';
    }
    final candidate = value == null ? null : '$value';
    return choices.contains(candidate) ? candidate : null;
  }

  dynamic normalizeSelectSubmission(String value) {
    if (value == 'none' && choices.contains('none')) {
      return null;
    }
    return value;
  }

  double primaryDoubleValue(dynamic value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is List<dynamic> && value.isNotEmpty) {
      final first = value.first;
      if (first is num) {
        return first.toDouble();
      }
      final parsedFirst = double.tryParse('$first');
      if (parsedFirst != null) {
        return parsedFirst;
      }
    }
    final parsed = double.tryParse('$value');
    return parsed ?? minimum ?? 0;
  }

  int? get divisions {
    if (minimum == null || maximum == null || step == null || step == 0) {
      return null;
    }
    final total = ((maximum! - minimum!) / step!).round();
    if (total <= 0 || total > 240) {
      return null;
    }
    return total;
  }

  dynamic castSliderValue(double value) {
    if (type == 'int') {
      return value.round();
    }
    final digits = step != null && step! < 1 ? 2 : 0;
    return double.parse(value.toStringAsFixed(digits));
  }

  String formatValue(dynamic value) {
    if (value == null) {
      return '--';
    }
    if (value is int) {
      return '$value';
    }
    if (value is double) {
      if ((value - value.round()).abs() < 0.0001) {
        return value.toStringAsFixed(0);
      }
      return value.toStringAsFixed(2);
    }
    return '$value';
  }

  String formatEditableValue(dynamic value) {
    if (value == null) {
      return '';
    }
    return '$value';
  }

  dynamic parseEditableValue(String rawValue) {
    final trimmed = rawValue.trim();
    if (trimmed.isEmpty) {
      return null;
    }
    if (type == 'int') {
      final parsed = int.tryParse(trimmed);
      if (parsed == null) {
        return null;
      }
      if (minimum != null && parsed < minimum!) {
        return minimum!.round();
      }
      if (maximum != null && parsed > maximum!) {
        return maximum!.round();
      }
      return parsed;
    }

    final parsed = double.tryParse(trimmed);
    if (parsed == null) {
      return null;
    }
    var normalized = parsed;
    if (minimum != null && normalized < minimum!) {
      normalized = minimum!;
    }
    if (maximum != null && normalized > maximum!) {
      normalized = maximum!;
    }
    return double.parse(normalized.toStringAsFixed(2));
  }
}
