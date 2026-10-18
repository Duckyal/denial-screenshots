import 'package:denial_screenshot/src/l10n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Locale locale, String Function(BuildContext) build) {
  return Localizations(
    locale: locale,
    delegates: const [DefaultWidgetsLocalizations.delegate],
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: Builder(builder: (context) => Text(build(context))),
    ),
  );
}

void main() {
  testWidgets('L.pick follows the UI locale', (tester) async {
    await tester.pumpWidget(
      _wrap(const Locale('zh'), (c) => L.pick(c, '删除模型', 'Delete model')),
    );
    expect(find.text('删除模型'), findsOneWidget);

    await tester.pumpWidget(
      _wrap(const Locale('en'), (c) => L.pick(c, '删除模型', 'Delete model')),
    );
    expect(find.text('Delete model'), findsOneWidget);

    // Any non-Chinese locale falls through to the English branch.
    await tester.pumpWidget(
      _wrap(const Locale('ja'), (c) => L.pick(c, '删除模型', 'Delete model')),
    );
    expect(find.text('Delete model'), findsOneWidget);
  });

  testWidgets('isChinese only true for zh', (tester) async {
    late bool zhHere;
    late bool enHere;
    await tester.pumpWidget(
      _wrap(const Locale('zh'), (c) {
        zhHere = L.isChinese(c);
        return '';
      }),
    );
    await tester.pumpWidget(
      _wrap(const Locale('en'), (c) {
        enHere = L.isChinese(c);
        return '';
      }),
    );
    expect(zhHere, isTrue);
    expect(enHere, isFalse);
  });
}
