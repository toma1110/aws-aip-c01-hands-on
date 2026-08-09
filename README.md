# AWS Certified Generative AI Developer - Professional (AIP-C01) Hands-on

Udemy講座「AWS Certified Generative AI Developer - Professional（AIP-C01）設計判断集中講座」の受講者向けhands-onリポジトリです。

## 利用方法

```bash
git clone https://github.com/toma1110/aws-aip-c01-hands-on.git
cd aws-aip-c01-hands-on
```

講義で指定されたSectionのREADMEを開き、記載された準備、実行、期待結果、トラブルシューティング、料金上の注意、cleanupの順に進めてください。

## Section構成

| Section | テーマ |
| --- | --- |
| `sections/s01/` | はじめに |
| `sections/s02/` | Foundation Model・Prompt・RAG |
| `sections/s03/` | Agent・Strands・MCP |
| `sections/s04/` | AI Safety・Security・Governance |
| `sections/s05/` | Cost・Performance・Observability |
| `sections/s06/` | Evaluation・Testing・Troubleshooting |
| `sections/s07/` | おわりに |

## 安全上の共通ルール

- 実際のcredential、個人情報、production dataをsampleやlogへ入れないでください。
- AWS resourceを作成する前に、対象Region、料金、service quota、必要権限を各SectionのREADMEで確認してください。
- 各hands-onのcleanupを完了し、削除後の確認まで実施してください。

## License

MIT License。詳細は[LICENSE](LICENSE)を参照してください。
