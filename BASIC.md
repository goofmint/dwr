# システム仕様書

## dev.goofmint.dw（Daily Work Capture System）

---

## 1. 目的

ユーザーのPC上の作業（画面・音声）をローカルで記録し、検索可能なテキストデータとして蓄積する。

* 完全ローカル処理
* シンプルな構成（shell + macOS標準機能）
* 再処理可能なファイルベース設計

---

## 2. 全体アーキテクチャ

```text
[Capture系] → incoming → [Process系] → processed → text
```

---

## 3. サービス構成（4サービス）

```text
1. image-capture
2. image-ocr
3. audio-capture
4. audio-transcribe
```

---

## 4. ディレクトリ構成

```bash
~/capture/

  image/
    incoming/
    processed/

  audio/
    incoming/
    processed/

  text/
    image/
      YYYY-MM-DD.txt
    audio/
      YYYY-MM-DD.txt
```

---

## 5. サービス仕様

---

### 5.1 image-capture

#### 役割

* スクリーンショット取得

#### 入力

* なし

#### 出力

```bash
~/capture/image/incoming/YYYYMMDD-HHMMSS.png
```

#### 処理

```bash
screencapture -x tmp.png
mv tmp.png incoming/<timestamp>.png
```

#### 実行方式

* launchd（StartInterval）

---

### 5.2 image-ocr

#### 役割

* 画像からテキスト抽出

#### 入力

```bash
image/incoming/*.png
```

#### 出力

```bash
text/image/YYYY-MM-DD.txt
```

#### 処理フロー

```text
incoming
↓
.processing に rename
↓
OCR（tesseract）
↓
日付ファイルに追記
↓
processed に移動
```

#### OCRコマンド

```bash
tesseract input.png stdout -l jpn+eng
```

#### トリガ

* launchd（WatchPaths）

---

### 5.3 audio-capture

#### 役割

* 音声録音（無音分割）

#### 入力

* マイク / 仮想オーディオデバイス

#### 出力

```bash
audio/incoming/YYYYMMDD-HHMMSS.wav
```

#### 処理

```bash
rec -c 1 -r 16000 output.wav silence 1 0.1 1% 1 2.0 1%
```

#### 特性

* 無音のみのデータは生成しない
* 音声ごとに自動分割

#### 実行方式

* 常時ループ（launchd）

---

### 5.4 audio-transcribe

#### 役割

* 音声 → テキスト変換

#### 入力

```bash
audio/incoming/*.wav
```

#### 出力

```bash
text/audio/YYYY-MM-DD.txt
```

#### 処理フロー

```text
incoming
↓
.processing に rename
↓
Swift CLI呼び出し（Speech.framework）
↓
日付ファイルに追記
↓
processed に移動
```

---

## 6. 音声認識仕様

### 使用フレームワーク

* Speech framework

### 実装

* Swift CLIラッパー
* shellから実行

```bash
./transcribe input.wav
```

### 制約

* オンデバイス認識（日本語対応環境のみ）
* 長時間音声非対応（分割前提）

---

## 7. 共通処理ルール

### 7.1 ファイル確定

```text
tmp → mv → 正式ファイル名
```

---

### 7.2 排他制御

```text
file.png → file.png.processing
```

---

### 7.3 冪等性

* `.processing` が残っても再処理可能
* processedに移動後は対象外

---

## 8. 常駐方式

すべて **launchd** で管理

---

### 種別

| サービス             | トリガ           |
| ---------------- | ------------- |
| image-capture    | StartInterval |
| image-ocr        | WatchPaths    |
| audio-capture    | 常時ループ         |
| audio-transcribe | WatchPaths    |

---

## 9. データ特性

### 画像

* フル解像度保存
* 重複判定は任意（compareで拡張可能）

### 音声

* 16kHz / mono
* 無音除外済み

### テキスト

* 日付単位で追記
* タイムスタンプ付き

---

## 10. セキュリティ

* 完全ローカル保存
* 外部送信なし
* Screen Recording権限必須
* マイク権限必須

---

## 11. 拡張ポイント

* 画像重複判定（ImageMagick compare）
* SQLite + FTS検索
* LLMによる日報生成
* ベクトル検索

---

## 12. 結論

```text
シンプルな4サービス構成で、
画面・音声・テキストのログ化をローカルで実現する
```

* shellベースで実装可能
* 再処理・拡張が容易
* 安定運用可能な最小構成
