import 'package:flutter/material.dart';

class InputAction extends StatefulWidget {
  const InputAction({required this.label, required this.onAdd, super.key});

  final String label;
  final void Function(String) onAdd;

  @override
  State<InputAction> createState() => InputActionState();
}

class InputActionState extends State<InputAction> {
  final TextEditingController _controller = TextEditingController();
  bool _showAddButton = false;

  void _onTextChanged() {
    setState(() {
      _showAddButton = _controller.text.isNotEmpty;
    });
  }

  void _onAddButtonPressed() {
    widget.onAdd(_controller.text);
    _controller.clear();
    setState(() {
      _showAddButton = false;
    });
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: widget.label,
            ),
          ),
        ),
        if (_showAddButton)
          IconButton(
            onPressed: _onAddButtonPressed,
            icon: const Icon(Icons.add),
            tooltip: 'Add',
          ),
      ],
    );
  }
}
