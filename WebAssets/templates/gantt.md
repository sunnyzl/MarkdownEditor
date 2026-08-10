# Gantt Chart Sample

```mermaid
gantt
    title POC 到 MVP 计划
    dateFormat YYYY-MM-DD
    section Epic-0
    POC 验证        :done, p1, 2024-08-06, 2d
    section Epic-1
    MVP 骨架        :p2, after p1, 5d
    编辑器+预览     :p3, after p2, 4d
    section Epic-2
    LaTeX+Mermaid   :p4, after p3, 3d
```
