import 'package:flutter/material.dart';
import 'package:host_protocol/host_protocol.dart';

import 'agent_controller.dart';

class NativeQuestionForm extends StatefulWidget {
  const NativeQuestionForm({
    super.key,
    required this.question,
    required this.submit,
  });
  final NativeQuestion question;
  final void Function(List<AgentQuestionAnswer>) submit;
  @override
  State<NativeQuestionForm> createState() => _NativeQuestionFormState();
}

class _NativeQuestionFormState extends State<NativeQuestionForm> {
  final _selected = <String, String>{};
  final _text = <String, TextEditingController>{};
  @override
  void initState() {
    super.initState();
    for (final q in widget.question.request.questions) {
      if (q.allowOther) _text[q.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final field in _text.values) {
      field.clear();
      field.dispose();
    }
    _text.clear();
    _selected.clear();
    super.dispose();
  }

  bool get _complete => widget.question.request.questions.every(
    (q) =>
        _selected.containsKey(q.id) || (_text[q.id]?.text.isNotEmpty ?? false),
  );
  @override
  Widget build(BuildContext context) {
    final request = widget.question.request;
    final enabled =
        !widget.question.replying && widget.question.unavailable == null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final q in request.questions) ...[
              Text(q.header),
              Text(q.text),
              for (final option in q.options)
                ListTile(
                  key: Key(
                    'question-choice-${request.requestId}-${q.id}-${option.id}',
                  ),
                  title: Text(option.label),
                  subtitle: option.description == null
                      ? null
                      : Text(option.description!),
                  selected: _selected[q.id] == option.id,
                  onTap: enabled
                      ? () => setState(() {
                          _selected[q.id] = option.id;
                          _text[q.id]?.clear();
                        })
                      : null,
                ),
              if (q.allowOther)
                TextField(
                  key: Key('question-text-${request.requestId}-${q.id}'),
                  controller: _text[q.id],
                  obscureText: q.secret,
                  enableSuggestions: !q.secret,
                  autocorrect: !q.secret,
                  enabled: enabled,
                  decoration: InputDecoration(
                    labelText: q.options.isEmpty ? 'Answer' : 'Other answer',
                  ),
                  onChanged: (_) => setState(() => _selected.remove(q.id)),
                ),
            ],
            if (widget.question.unavailable != null)
              Text(widget.question.unavailable!),
            FilledButton(
              key: Key('question-submit-${request.requestId}'),
              onPressed: enabled && _complete
                  ? () => widget.submit([
                      for (final q in request.questions)
                        AgentQuestionAnswer(
                          questionId: q.id,
                          values: [_selected[q.id] ?? _text[q.id]!.text],
                        ),
                    ])
                  : null,
              child: Text(
                widget.question.unavailable != null
                    ? 'Answer unavailable'
                    : widget.question.replying
                    ? 'Waiting for answer outcome'
                    : 'Submit answer',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
