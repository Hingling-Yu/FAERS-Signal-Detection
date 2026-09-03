# FAERS Signal Detection Project

## 项目概述
FDA FAERS 不良事件信号检测项目。用 SAS + SQL 完成数据清洗、信号检测（PRR/ROR）、可视化。
服务求职方向：PV Case Processor → Drug Safety Data Analyst → RWE Analyst。

## 数据
`raw-data/` 下 4 个季度的 FAERS ASCII 数据（2025Q3–2026Q2），`$` 分隔符，7 张表 + DELETE 文件。
每季度约 40 万 cases，合计约 160 万。

## 工作流
- Cowork 负责规划、文档、口径；VS Code + Claude Code（Coco）负责写代码（含 SAS / SQL / Python）
- SAS 执行环境是浏览器端 SAS OnDemand for Academics（SAS Studio），不是本地
  - Coco 在 VS Code 写 .sas 文件 → Angel 复制到 SAS Studio 跑 → 结果回来 review
  - .sas 文件住在 repo 里，Coco 写、Coco commit
- SQL (MySQL) 和 Python 在 VS Code 终端直接跑
- 三步 gate workflow：Plan → Execute → Review
- 所有对外交付物英文
- 参考 CHARTER.md 了解 scope 和 timeline

## 技术栈
- SAS（SAS OnDemand for Academics / SAS Studio）：数据导入、清洗、PRR/ROR 计算（主力，为了补 SAS 代码项目 gap）
- SQL (MySQL)：数据仓库、查询、聚合
- Python：辅助可视化（matplotlib/seaborn）
- Tableau：最终 dashboard

## SAS Studio 注意事项
- 5GB 免费存储，上传 FAERS .txt 文件到 Files 区域
- 输出文件（CSV/数据集）从 SAS Studio 下载回本地 repo 的 output/ 目录
- SAS log 也保存回 output/logs/

## 文件结构约定
见 CHARTER.md § Folder Structure

## 分工提醒（重要）
- **Cowork（这个 session）**：规划、文档、教学、review、STATUS.md 维护
- **Coco（VS Code Claude Code）**：所有代码的编写和修改（.sas / .sql / .py）
- **Cowork 不要直接改代码文件**，发现代码问题时告诉 Angel 让 Coco 去改
- 00_config.sas 是唯一例外（属于 setup task，由 Cowork 初始创建）

## Context Window 交接规则
- 当 Angel 说"开新 context window"时，Cowork 直接在对话里生成交接 prompt（可复制粘贴的文字）
- **不要**生成 .md 文件，直接给对话里的 clipboard 版本
- 交接 prompt 应包含：当前进度、下一步、已知问题、SAS 学习进度

## SAS ODA 文件夹结构（已建好）
```
/home/u64291357/mydata/
├── sas/
│   ├── 00_config.sas        ← 已上传并跑通
│   └── macros/
├── output/
│   ├── clean/
│   ├── signal/
│   ├── tables/
│   ├── figures/
│   ├── logs/
│   └── qc/
└── docs/
    └── fda_notes/
```
FAERS 数据文件（faers_ascii_2025q3/ 等）还没上传到 SAS ODA。
