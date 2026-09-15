# 0003 — 产品名定为 Sukiru（原 Gino）

产品原名 Gino（技能的日语读音）与真实存在的 Python asyncio ORM `python-gino/gino` 撞名，目标用户在 GitHub 搜索路径上会先撞见后者；仓库私有未发布，正是零成本改名窗口（2026-09-14 grilling 拍板）。新名 **Sukiru**（スキル，"skill" 的片假名外来语）：GitHub 无实质撞名（仅一个个人练手项目和一个单仓库 org），延续同一命名逻辑，且与"旧路线退役、新路线"的产品故事同构。公开发布前需查 `sukiru.app` / `.com` 域名可用性（`sukiru.co` 已存在，小旗）。

## Consequences

- 仓库手术时连 remote 一起改名（GitHub 私有仓库 rename，无历史损失）。
- ADR 中的历史叙述保留 "Gino" 字样（指旧 Rust 实现），现行产品一律用 Sukiru。
- 定位句（2026-09-14 拍板，务实版）："**Sukiru is the fast and tiny macOS native skill manager that manages your skills by orchestrating npx skills and gh skill.**" 主标走务实直白路线（有意否决更营销化的三个候选）；裁判叙事、两本账本与碰撞矩阵证据留给 README 正文展开。
