# AWS Certified Generative AI Developer - Professional (AIP-C01) Hands-on

Udemy講座「AWS Certified Generative AI Developer - Professional（AIP-C01）設計判断集中講座」の受講者向けhands-onリポジトリです。

このbaselineでは、Sectionごとの配置と安全上の共通ルールだけを提供します。実行可能な教材は、各Sectionの制作・技術検証・独立レビューが完了した後に追加されます。

## 利用方法

```bash
git clone https://github.com/toma1110/aws-aip-c01-hands-on.git
cd aws-aip-c01-hands-on
```

講義で指定されたSectionのREADMEを開き、記載された準備、実行、期待結果、トラブルシューティング、料金上の注意、cleanupの順に進めてください。講義でcommit SHAが指定されている場合は、そのcommitをcheckoutして使用してください。

## Section構成

| Section | テーマ | Hands-on |
| --- | --- | --- |
| `sections/s01/` | はじめに | なし |
| `sections/s02/` | Foundation Model・Prompt・RAG | 低品質RAGの測定と改善（追加予定） |
| `sections/s03/` | Agent・Strands・MCP | Human Approvalによるtool実行制御（追加予定） |
| `sections/s04/` | AI Safety・Security・Governance | Guardrails・PII・IAMの多層防御（追加予定） |
| `sections/s05/` | Cost・Performance・Observability | なし |
| `sections/s06/` | Evaluation・Testing・Troubleshooting | Regression Gate（追加予定） |
| `sections/s07/` | おわりに | resourceの完全削除と残存確認（追加予定） |

## 安全上の共通ルール

- 実際のcredential、個人情報、production dataをsampleやlogへ入れないでください。
- AWS resourceを作成する前に、対象Region、料金、service quota、必要権限を各SectionのREADMEで確認してください。
- 各hands-onのcleanupを完了し、削除後の確認まで実施してください。
- secretと思われる値をcommitした場合は、削除だけで済ませずcredentialを直ちに無効化・再発行してください。

問題の報告方法は[SECURITY.md](SECURITY.md)を参照してください。

## License

MIT License。詳細は[LICENSE](LICENSE)を参照してください。
