import 'package:flutter/widgets.dart';

import 'package:plot/widget/widget.dart';

class InputAction extends StatefulWidget {
  const InputAction({required this.label, required this.onAdd, super.key});

  final String label;
  final void Function(String) onAdd;

  @override
  State<InputAction> createState() => InputActionState();
}

class InputActionState extends State<InputAction> {
  final TextEditingController _controller = TextEditingController();
  void _onSubmit() {
    widget.onAdd(_controller.text);
    _controller.clear();
  }

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            label: widget.label,
            onSubmitted: (value) {
              _onSubmit();
            },
            controller: _controller,
          ),
        ),
      ],
    );
  }
}
