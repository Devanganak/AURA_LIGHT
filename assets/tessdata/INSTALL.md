Offline Malayalam OCR model setup

1. Download `mal.traineddata` from the `tessdata_fast` repository.
2. Place the file at `assets/tessdata/mal.traineddata`.
3. Run `flutter pub get`.
4. Rebuild the app.

Notes
- Keep only `mal.traineddata` to control app size.
- This app falls back to ML Kit OCR if the Malayalam model file is not present.
