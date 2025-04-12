import 'package:flutter/widgets.dart';
import 'package:flutter_hooks/flutter_hooks.dart';

export 'package:flutter_hooks/flutter_hooks.dart';

(TextEditingController nameController, String name) useTextEditingValue() {
  final controller = useTextEditingController();
  final text = useState("");
  useEffect(() {
    void textChangeListener() {
      text.value = controller.text;
    }

    controller.addListener(textChangeListener);
    return () => controller.removeListener(textChangeListener);
  }, [controller]);
  return (controller, text.value);
}
