# Спроси Вселенную · мобильный стенд

Flutter-приложение проверяет текст локальной моделью multilingual-e5-small. Для всех вопросов допуск закрыт. Экран поддерживает русский и английский языки.

Для подготовки нужны Python 3, Flutter 3.50.1, а для сборки iOS — Xcode и CocoaPods. Из корня репозитория выполните:

```sh
python3 -m research.prepare_mobile
cd mobile
flutter config --no-enable-swift-package-manager
flutter pub get --enforce-lockfile
flutter build ios --release --no-codesign --no-pub
python3 tool/check_app.py build/ios/iphoneos/Runner.app
```

На Mac с работающим симулятором iPhone выполните `flutter test --no-pub -d <ID_симулятора> integration_test/ios_model_test.dart` из каталога `mobile`. Для установки на телефон требуется подпись в Xcode.
